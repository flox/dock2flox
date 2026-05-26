#!/usr/bin/env bash
# dock2flox Docker Compose parser
# Uses a structured YAML parser when python3/PyYAML are available, then emits
# the same IR records as the Dockerfile parser. A small legacy fallback remains
# for systems without python3-yaml; it emits review markers instead of silently
# pretending to understand advanced Compose features.

# Requires: lib/core.sh, lib/mapper_base_images.sh sourced first

parse_compose() {
    local compose_file="$1"
    local ir_file="$2"

    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi

    log_info "Parsing: $compose_file"

    local parsed=0
    if command -v python3 >/dev/null 2>&1 && [[ -f "$DOCK2FLOX_ROOT/lib/parser_compose.py" ]]; then
        local parsed_ir
        parsed_ir=$(dock2flox_mktemp)
        if python3 "$DOCK2FLOX_ROOT/lib/parser_compose.py" "$compose_file" > "$parsed_ir"; then
            cat "$parsed_ir" >> "$ir_file"
            parsed=1
        else
            log_warn "Structured Compose parser failed; using conservative fallback"
            ir_review "$ir_file" "compose-parser" "structured parser failed; fallback parser used for $compose_file" "0"
        fi
    else
        log_warn "python3/PyYAML not available; using conservative Compose fallback"
        ir_review "$ir_file" "compose-parser" "python3/PyYAML unavailable; advanced Compose semantics may be incomplete" "0"
    fi

    if [[ "$parsed" -eq 0 ]]; then
        _parse_compose_fallback "$compose_file" "$ir_file"
    fi

    _resolve_service_boundaries "$ir_file"
}

_parse_compose_fallback() {
    local compose_file="$1"
    local ir_file="$2"

    local in_services=0
    local current_service=""
    local service_indent=0
    local line_num=0
    local current_key=""
    local -A services_found=()

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        local stripped="${line#"${line%%[![:space:]]*}"}"
        local current_indent=$(( ${#line} - ${#stripped} ))

        if [[ "$current_indent" -eq 0 && "$stripped" == "services:" ]]; then
            in_services=1
            continue
        elif [[ "$current_indent" -eq 0 && "$stripped" != "services:" ]]; then
            in_services=0
            current_service=""
            continue
        fi

        [[ "$in_services" -eq 0 ]] && continue

        if [[ "$current_indent" -eq 2 && "$stripped" == *":" ]]; then
            current_service="${stripped%%:*}"
            current_service="${current_service// /}"
            service_indent=$current_indent
            services_found["$current_service"]=1
            current_key=""
            continue
        fi

        [[ -z "$current_service" ]] && continue

        if [[ "$current_indent" -gt "$service_indent" ]]; then
            _parse_compose_fallback_property "$stripped" "$current_service" "$ir_file" "$line_num" current_key
        fi
    done < "$compose_file"

    log_info "Parsed ${#services_found[@]} service(s) with fallback Compose parser: ${!services_found[*]}"
}

_parse_compose_fallback_property() {
    local stripped="$1"
    local service="$2"
    local ir_file="$3"
    local line_num="$4"
    local -n current_key_ref="$5"

    if [[ "$stripped" == *":"* && "$stripped" != "- "* ]]; then
        local key="${stripped%%:*}"
        local value="${stripped#*:}"
        key="${key// /}"
        value="${value# }"

        if [[ -z "${value// /}" ]]; then
            current_key_ref="$key"
            return 0
        fi

        value=$(_compose_strip_quotes "$value")
        case "$key" in
            image)
                printf 'SERVICE_IMAGE%s%s%s%s%s%s%s%s\n' "$IR_DELIM" "$service" "$IR_DELIM" "$(_ir_encode "$value")" "$IR_DELIM" "$(_ir_encode "$service")" "$IR_DELIM" "$line_num" >> "$ir_file"
                ir_var "$ir_file" "DOCK2FLOX_COMPOSE_$(printf '%s' "$service" | tr '[:lower:]-' '[:upper:]_')_IMAGE" "$value" "$line_num"
                ;;
            command|entrypoint)
                printf 'SERVICE_CMD%s%s%s%s%s%s\n' "$IR_DELIM" "$service" "$IR_DELIM" "$(_ir_encode "$value")" "$IR_DELIM" "$line_num" >> "$ir_file"
                ;;
            build|container_name|hostname|restart|depends_on|networks|healthcheck|profiles|secrets|configs|env_file)
                ir_review "$ir_file" "compose-fallback" "service $service: $key seen but fallback parser cannot fully model it" "$line_num"
                ;;
        esac
    elif [[ "$stripped" == "- "* ]]; then
        local item="${stripped#- }"
        item=$(_compose_strip_quotes "$item")
        case "$current_key_ref" in
            environment)
                if [[ "$item" == *=* ]]; then
                    local name="${item%%=*}"
                    local value="${item#*=}"
                    ir_var "$ir_file" "$name" "$value" "$line_num"
                fi
                ;;
            ports)
                local container_port="$item"
                if [[ "$container_port" == *":"* ]]; then
                    container_port="${container_port##*:}"
                fi
                container_port="${container_port%%/*}"
                local prefix
                prefix=$(printf '%s' "$service" | tr '[:lower:]-' '[:upper:]_')
                ir_var "$ir_file" "${prefix}_PORT" "$container_port" "$line_num"
                ir_review "$ir_file" "compose-networking" "service $service: port mapping preserved by fallback parser: $item" "$line_num"
                ;;
            volumes|secrets|configs)
                ir_review "$ir_file" "compose-fallback" "service $service: $current_key_ref item preserved for manual review: $item" "$line_num"
                ;;
        esac
    fi
}

_compose_strip_quotes() {
    local value="$1"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s' "$value"
}

_resolve_service_boundaries() {
    local ir_file="$1"
    local mode="${DOCK2FLOX_SERVICES_MODE:-container}"

    local service_images
    service_images=$({ grep "^SERVICE_IMAGE${IR_DELIM}" "$ir_file" 2>/dev/null || true; })
    [[ -z "$service_images" ]] && return 0

    while IFS="$IR_DELIM" read -r _ service image orig_name line_num; do
        image=$(_ir_decode "$image")
        orig_name=$(_ir_decode "$orig_name")
        # Fall back to sanitized name if original wasn't provided
        [[ -z "$orig_name" ]] && orig_name="$service"
        local decision=""

        case "$mode" in
            flox)
                decision="flox"
                ;;
            compose)
                decision="compose"
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
            *)
                decision="container"
                ;;
        esac

        _emit_service_decision "$service" "$image" "$decision" "$ir_file" "$line_num" "$orig_name"
    done <<< "$service_images"

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
        "Service '$service' (image: $image):" \
        "container" "compose" "flox")
    printf '%s' "$choice"
}

_emit_service_decision() {
    local service="$1"
    local image="$2"
    local decision="$3"
    local ir_file="$4"
    local line_num="$5"
    local orig_name="${6:-$service}"

    local cmd=""
    cmd=$({ grep -F "SERVICE_CMD${IR_DELIM}${service}${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | tail -1 | cut -d "$IR_DELIM" -f3)
    [[ -n "$cmd" ]] && cmd=$(_ir_decode "$cmd")

    case "$decision" in
        flox)
            map_base_image "$image" "$ir_file" "$line_num"
            local service_cmd
            service_cmd=$(_generate_service_command "$service" "$image" "$cmd")
            if [[ -n "$service_cmd" ]]; then
                ir_service "$ir_file" "$service" "$service_cmd" "$line_num"
            fi
            ;;
        compose)
            _emit_container_vars "$service" "$image" "$ir_file" "$line_num"
            # Use original YAML service name for docker compose commands
            ir_service_compose "$ir_file" "$service" \
                "docker compose up -d $orig_name" \
                "docker compose stop $orig_name && docker compose rm -f $orig_name" \
                "$line_num"
            ;;
        container)
            _emit_container_vars "$service" "$image" "$ir_file" "$line_num"
            ir_skip "$ir_file" "$service (image: $image)" "kept as external container" "$line_num"
            ir_review "$ir_file" "compose-service" "service $service kept as external container image $image" "$line_num"
            ;;
    esac
}

_generate_service_command() {
    local service="$1"
    local image="$2"
    local cmd="$3"

    if [[ -n "$cmd" ]]; then
        printf '%s' "$cmd"
        return 0
    fi

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

    local image_base="${image%%:*}"
    image_base="${image_base##*/}"

    local prefix
    prefix=$(printf '%s' "$service" | tr '[:lower:]-' '[:upper:]_')

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
