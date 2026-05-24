#!/usr/bin/env bash
# dock2flox Docker Compose parser
# Reads a docker-compose.yml and emits IR records
# Uses simple line-by-line YAML parsing (no external YAML library needed)

# Requires: lib/core.sh, lib/mapper_base_images.sh sourced first

parse_compose() {
    local compose_file="$1"
    local ir_file="$2"

    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi

    log_info "Parsing: $compose_file"

    local in_services=0
    local current_service=""
    local current_key=""
    local indent_level=0
    local service_indent=0
    local line_num=0
    local -A services_found=()

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Skip empty lines and comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Calculate indent
        local stripped="${line#"${line%%[![:space:]]*}"}"
        local current_indent=$(( ${#line} - ${#stripped} ))

        # Top-level key detection
        if [[ "$current_indent" -eq 0 && "$stripped" == "services:" ]]; then
            in_services=1
            continue
        elif [[ "$current_indent" -eq 0 && "$stripped" != "services:" ]]; then
            in_services=0
            current_service=""
            continue
        fi

        if [[ "$in_services" -eq 0 ]]; then
            continue
        fi

        # Service-level detection (typically 2-space indent under services:)
        if [[ "$current_indent" -eq 2 && "$stripped" == *":" ]]; then
            current_service="${stripped%%:*}"
            current_service="${current_service// /}"
            service_indent=$current_indent
            services_found["$current_service"]=1
            current_key=""
            log_verbose "Found service: $current_service (line $line_num)"
            continue
        fi

        # Skip if no current service
        [[ -z "$current_service" ]] && continue

        # Service properties (4-space indent typically)
        if [[ "$current_indent" -gt "$service_indent" ]]; then
            _parse_compose_property "$stripped" "$current_service" "$current_indent" "$ir_file" "$line_num"
        fi

    done < "$compose_file"

    # Handle service boundary decisions
    _resolve_service_boundaries "$ir_file"

    log_info "Parsed ${#services_found[@]} service(s): ${!services_found[*]}"
}

# --- Internal helpers ---

# State for multi-line values
declare -g _compose_current_key=""
declare -g _compose_in_list=0
declare -g _compose_list_key=""

_parse_compose_property() {
    local stripped="$1"
    local service="$2"
    local indent="$3"
    local ir_file="$4"
    local line_num="$5"

    # Detect key: value pairs
    if [[ "$stripped" == *":"* && "$stripped" != "- "* ]]; then
        local key="${stripped%%:*}"
        local value="${stripped#*: }"
        key="${key// /}"

        # Handle empty value (block follows)
        if [[ "$value" == "${stripped%%:*}:" || -z "${value// /}" || "$value" == "$key:" ]]; then
            _compose_current_key="$key"
            _compose_in_list=0
            return 0
        fi

        # Strip quotes from value
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        case "$key" in
            image)
                _handle_compose_image "$service" "$value" "$ir_file" "$line_num"
                ;;
            command)
                _handle_compose_command "$service" "$value" "$ir_file" "$line_num"
                ;;
            container_name|hostname|restart|depends_on|networks|healthcheck)
                ir_skip "$ir_file" "$service.$key" "compose orchestration" "$line_num"
                ;;
            *)
                log_verbose "Compose: $service.$key = $value (unhandled)"
                ;;
        esac

    # Detect list items (- value)
    elif [[ "$stripped" == "- "* ]]; then
        local item="${stripped#- }"
        # Strip quotes
        item="${item#\"}"
        item="${item%\"}"
        item="${item#\'}"
        item="${item%\'}"

        case "$_compose_current_key" in
            environment)
                _handle_compose_env_item "$service" "$item" "$ir_file" "$line_num"
                ;;
            ports)
                _handle_compose_port "$service" "$item" "$ir_file" "$line_num"
                ;;
            volumes)
                ir_skip "$ir_file" "$service.volumes: $item" "compose volume mount" "$line_num"
                ;;
            *)
                log_verbose "Compose list item ($service.$_compose_current_key): $item"
                ;;
        esac
    fi
}

_handle_compose_image() {
    local service="$1"
    local image="$2"
    local ir_file="$3"
    local line_num="$4"

    # Store image info for service boundary decision
    # Tag as SERVICE_IMAGE in IR for later processing
    printf 'SERVICE_IMAGE%s%s%s%s%s%s\n' "$IR_DELIM" "$service" "$IR_DELIM" "$(_ir_encode "$image")" "$IR_DELIM" "$line_num" >> "$ir_file"
}

_handle_compose_command() {
    local service="$1"
    local command="$2"
    local ir_file="$3"
    local line_num="$4"

    # Store for service boundary decision
    printf 'SERVICE_CMD%s%s%s%s%s%s\n' "$IR_DELIM" "$service" "$IR_DELIM" "$(_ir_encode "$command")" "$IR_DELIM" "$line_num" >> "$ir_file"
}

_handle_compose_env_item() {
    local service="$1"
    local item="$2"
    local ir_file="$3"
    local line_num="$4"

    # Parse KEY=VALUE
    if [[ "$item" == *"="* ]]; then
        local name="${item%%=*}"
        local value="${item#*=}"
        ir_var "$ir_file" "$name" "$value" "$line_num"
    fi
}

_handle_compose_port() {
    local service="$1"
    local port_spec="$2"
    local ir_file="$3"
    local line_num="$4"

    # Extract host port from "HOST:CONTAINER" or "HOST:CONTAINER/proto"
    local host_port container_port
    if [[ "$port_spec" == *":"* ]]; then
        host_port="${port_spec%%:*}"
        container_port="${port_spec#*:}"
        container_port="${container_port%%/*}"
    else
        host_port="$port_spec"
        container_port="$port_spec"
    fi

    # Emit as a variable hint (e.g., SERVICE_PORT)
    local var_name
    var_name=$(echo "${service}_PORT" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    ir_var "$ir_file" "$var_name" "$container_port" "$line_num"

    ir_skip "$ir_file" "$service ports: $port_spec" "container networking" "$line_num"
}

# --- Service boundary resolution ---

_resolve_service_boundaries() {
    local ir_file="$1"

    local mode="${DOCK2FLOX_SERVICES_MODE:-container}"

    # Collect SERVICE_IMAGE records
    local service_images
    service_images=$({ grep "^SERVICE_IMAGE${IR_DELIM}" "$ir_file" 2>/dev/null || true; })

    [[ -z "$service_images" ]] && return 0

    while IFS="$IR_DELIM" read -r _ service image line_num; do
        image=$(_ir_decode "$image")
        local decision=""

        case "$mode" in
            flox)
                decision="flox"
                ;;
            container)
                decision="container"
                ;;
            prompt)
                if dock2flox_is_interactive; then
                    decision=$(_prompt_service_decision "$service" "$image")
                else
                    decision="container"
                fi
                ;;
        esac

        _emit_service_decision "$service" "$image" "$decision" "$ir_file" "$line_num"

    done <<< "$service_images"

    # Remove temporary SERVICE_IMAGE and SERVICE_CMD records
    local cleaned
    cleaned=$(dock2flox_mktemp)
    { grep -v "^SERVICE_IMAGE${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | { grep -v "^SERVICE_CMD${IR_DELIM}" 2>/dev/null || true; } > "$cleaned"
    cp "$cleaned" "$ir_file"
}

_prompt_service_decision() {
    local service="$1"
    local image="$2"

    local choice
    choice=$(dock2flox_prompt_choice \
        "Service '$service' (image: $image) — convert to Flox service or keep as container?" \
        "container" "flox")
    printf '%s' "$choice"
}

_emit_service_decision() {
    local service="$1"
    local image="$2"
    local decision="$3"
    local ir_file="$4"
    local line_num="$5"

    # Get any command override
    local cmd=""
    cmd=$({ grep -F "SERVICE_CMD${IR_DELIM}${service}${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | head -1 | cut -d "$IR_DELIM" -f3)
    [[ -n "$cmd" ]] && cmd=$(_ir_decode "$cmd")

    case "$decision" in
        flox)
            # Map image to a Flox service definition
            map_base_image "$image" "$ir_file" "$line_num"

            # Generate service command
            local service_cmd
            service_cmd=$(_generate_service_command "$service" "$image" "$cmd")
            if [[ -n "$service_cmd" ]]; then
                ir_service "$ir_file" "$service" "$service_cmd" "$line_num"
            fi
            ;;
        container)
            # Emit connection variables only
            _emit_container_vars "$service" "$image" "$ir_file" "$line_num"
            ir_skip "$ir_file" "$service (image: $image)" "kept as external container" "$line_num"
            ;;
    esac
}

_generate_service_command() {
    local service="$1"
    local image="$2"
    local cmd="$3"

    # Use explicit command if provided
    if [[ -n "$cmd" ]]; then
        printf '%s' "$cmd"
        return 0
    fi

    # Generate default commands for well-known services
    local image_base="${image%%:*}"
    image_base="${image_base##*/}"

    case "$image_base" in
        postgres|postgresql)
            printf 'exec postgres -D "$FLOX_ENV_CACHE/pgdata" -p "${PGPORT:-5432}"'
            ;;
        redis)
            printf 'exec redis-server --port "${REDIS_PORT:-6379}" --dir "$FLOX_ENV_CACHE/redis"'
            ;;
        mysql|mariadb)
            printf 'exec mysqld --datadir="$FLOX_ENV_CACHE/mysql"'
            ;;
        *)
            printf ''
            ;;
    esac
}

_emit_container_vars() {
    local service="$1"
    local image="$2"
    local ir_file="$3"
    local line_num="$4"

    # Emit standard connection variables for well-known services
    local image_base="${image%%:*}"
    image_base="${image_base##*/}"

    local prefix
    prefix=$(echo "$service" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    case "$image_base" in
        postgres|postgresql)
            ir_var "$ir_file" "PGHOST" "localhost" "$line_num"
            ir_var "$ir_file" "PGPORT" "5432" "$line_num"
            ;;
        redis)
            ir_var "$ir_file" "REDIS_HOST" "localhost" "$line_num"
            ir_var "$ir_file" "REDIS_PORT" "6379" "$line_num"
            ;;
        mysql|mariadb)
            ir_var "$ir_file" "MYSQL_HOST" "localhost" "$line_num"
            ir_var "$ir_file" "MYSQL_PORT" "3306" "$line_num"
            ;;
        mongo|mongodb)
            ir_var "$ir_file" "MONGO_HOST" "localhost" "$line_num"
            ir_var "$ir_file" "MONGO_PORT" "27017" "$line_num"
            ;;
        *)
            ir_var "$ir_file" "${prefix}_HOST" "localhost" "$line_num"
            ;;
    esac
}
