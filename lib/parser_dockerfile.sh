#!/usr/bin/env bash
# dock2flox Dockerfile parser
# Reads a Dockerfile and emits IR records to a given IR file.

# Requires: lib/core.sh, lib/mapper_packages.sh, lib/mapper_base_images.sh sourced first

parse_dockerfile() {
    local dockerfile="$1"
    local ir_file="$2"

    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not found: $dockerfile"
        return 1
    fi

    log_info "Parsing: $dockerfile"

    # State tracking
    local -A arg_table=()       # ARG name -> value
    local stage_index=0         # current FROM stage index
    local stage_name=""         # current FROM stage AS name
    local final_stage_start=0   # line number where final stage begins
    local line_num=0
    local pkg_manager=""        # detected package manager (apt/apk/yum)

    # Pre-process: read file, collapse line continuations
    local processed
    processed=$(dock2flox_mktemp)
    _dockerfile_collapse_continuations "$dockerfile" > "$processed"

    # First pass: find final stage start line
    local total_stages=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*FROM[[:space:]] ]]; then
            total_stages=$((total_stages + 1))
        fi
    done < "$processed"

    # Second pass: parse instructions
    local current_stage=0
    line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Extract instruction keyword
        local instruction
        instruction=$(_dockerfile_get_instruction "$line")

        case "$instruction" in
            FROM)
                current_stage=$((current_stage + 1))
                _parse_from "$line" "$ir_file" "$line_num" "$current_stage" "$total_stages"
                ;;
            ARG)
                _parse_arg "$line" "$line_num"
                ;;
            ENV)
                # Only emit from final stage
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_env "$line" "$ir_file" "$line_num"
                fi
                ;;
            RUN)
                # Only emit from final stage
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_run "$line" "$ir_file" "$line_num"
                fi
                ;;
            EXPOSE)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_expose "$line" "$ir_file" "$line_num"
                fi
                ;;
            COPY|ADD|WORKDIR|USER|CMD|ENTRYPOINT|HEALTHCHECK|STOPSIGNAL|SHELL|LABEL|VOLUME)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    ir_skip "$ir_file" "$instruction" "OCI-specific instruction" "$line_num"
                fi
                ;;
        esac
    done < "$processed"

    log_info "Parsed $line_num lines, $total_stages stage(s)"
}

# --- Internal helpers ---

_dockerfile_collapse_continuations() {
    local file="$1"
    # Join lines ending with \ with the next line
    awk '{
        if (/\\$/) {
            sub(/\\$/, "")
            printf "%s ", $0
        } else {
            print $0
        }
    }' "$file"
}

_dockerfile_get_instruction() {
    local line="$1"
    # Extract first word, uppercase
    echo "$line" | awk '{print toupper($1)}'
}

_substitute_args() {
    local text="$1"
    local key val safe_val
    for key in "${!arg_table[@]}"; do
        val="${arg_table[$key]}"
        # Escape & in replacement string (bash treats & as matched text in ${//})
        safe_val="${val//\\/\\\\}"
        safe_val="${safe_val//&/\\&}"
        text="${text//\$\{$key\}/$safe_val}"
        text="${text//\$$key/$safe_val}"
    done
    printf '%s' "$text"
}

_parse_from() {
    local line="$1" ir_file="$2" line_num="$3" current_stage="$4" total_stages="$5"

    # FROM [--platform=...] image[:tag] [AS name]
    local image_spec
    image_spec=$(echo "$line" | sed -E 's/^FROM\s+(--platform=[^ ]+\s+)?//i' | awk '{print $1}')
    image_spec=$(_substitute_args "$image_spec")

    # Extract AS name if present
    if [[ "$line" =~ [Aa][Ss][[:space:]]+([a-zA-Z0-9_-]+) ]]; then
        stage_name="${BASH_REMATCH[1]}"
    else
        stage_name=""
    fi

    # Only map base image for the final stage
    if [[ "$current_stage" -eq "$total_stages" ]]; then
        map_base_image "$image_spec" "$ir_file" "$line_num"
    else
        ir_skip "$ir_file" "FROM $image_spec (stage $current_stage)" "intermediate build stage" "$line_num"
    fi
}

_parse_arg() {
    local line="$1" line_num="$2"

    # ARG NAME=value or ARG NAME
    local arg_body
    arg_body=$(echo "$line" | sed -E 's/^ARG\s+//i')

    local name value
    if [[ "$arg_body" == *"="* ]]; then
        name="${arg_body%%=*}"
        value="${arg_body#*=}"
        # Strip quotes from value
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
    else
        name="$arg_body"
        value=""
    fi

    arg_table["$name"]="$value"
    log_verbose "ARG $name=$value (line $line_num)"
}

_parse_env() {
    local line="$1" ir_file="$2" line_num="$3"

    # Check skip patterns
    if _should_skip_env "$line"; then
        ir_skip "$ir_file" "ENV (skipped boilerplate)" "OCI boilerplate" "$line_num"
        return 0
    fi

    # ENV NAME=value or ENV NAME value (legacy)
    local env_body
    env_body=$(echo "$line" | sed -E 's/^ENV\s+//i')
    env_body=$(_substitute_args "$env_body")

    # Handle multiple KEY=VALUE pairs on one line
    # Also handle legacy: ENV KEY VALUE
    if [[ "$env_body" == *"="* ]]; then
        # Modern syntax: KEY=VALUE [KEY2=VALUE2 ...]
        # Simple approach: split on spaces, handle quoted values
        _parse_env_keyvalue "$env_body" "$ir_file" "$line_num"
    else
        # Legacy syntax: ENV KEY VALUE
        local name value
        name=$(echo "$env_body" | awk '{print $1}')
        value=$(echo "$env_body" | awk '{$1=""; print substr($0,2)}')
        _emit_env_record "$name" "$value" "$ir_file" "$line_num"
    fi
}

_parse_env_keyvalue() {
    local body="$1" ir_file="$2" line_num="$3"

    # Parse KEY=VALUE pairs (handles simple quoting)
    local remainder="$body"
    while [[ -n "$remainder" ]]; do
        remainder="${remainder#"${remainder%%[![:space:]]*}"}" # ltrim
        [[ -z "$remainder" ]] && break

        local name value
        name="${remainder%%=*}"
        remainder="${remainder#*=}"

        # Extract value (handle quotes)
        if [[ "$remainder" == \"* ]]; then
            remainder="${remainder#\"}"
            value="${remainder%%\"*}"
            remainder="${remainder#*\"}"
        elif [[ "$remainder" == \'* ]]; then
            remainder="${remainder#\'}"
            value="${remainder%%\'*}"
            remainder="${remainder#*\'}"
        else
            value="${remainder%% *}"
            remainder="${remainder#* }"
            [[ "$remainder" == "$value" ]] && remainder=""
        fi

        _emit_env_record "$name" "$value" "$ir_file" "$line_num"
    done
}

_emit_env_record() {
    local name="$1" value="$2" ir_file="$3" line_num="$4"

    # Classify: if value references PATH or is path-like, use HOOK; otherwise VAR
    if [[ "$value" == *'$PATH'* || "$value" == *'${'* || "$value" == *'$('* ]]; then
        ir_hook "$ir_file" "050" "export $name=\"$value\"" "$line_num"
    else
        ir_var "$ir_file" "$name" "$value" "$line_num"
    fi
}

_parse_run() {
    local line="$1" ir_file="$2" line_num="$3"

    local run_body
    run_body=$(echo "$line" | sed -E 's/^RUN\s+//i')
    run_body=$(_substitute_args "$run_body")

    # Enhancement 1: Check full RUN body for known installer patterns BEFORE splitting
    # Emit install record if found, but only short-circuit if the RUN has no other
    # meaningful commands (apt/pip/npm installs)
    local _installer_found=0
    if _detect_known_installer "$run_body" "$ir_file" "$line_num"; then
        _installer_found=1
        # Short-circuit only if no other package managers present
        if ! [[ "$run_body" =~ (apt-get|apk|pip|pip3|npm)[[:space:]]+(install|add) ]]; then
            return 0
        fi
    fi

    # Split on && to handle chained commands
    local IFS_BAK="$IFS"
    local -a commands=()
    _split_run_commands "$run_body" commands

    local cmd
    for cmd in "${commands[@]}"; do
        # Trim whitespace
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        cmd="${cmd%"${cmd##*[![:space:]]}"}"
        [[ -z "$cmd" ]] && continue

        # Skip if matches skip patterns
        if _should_skip_run "$cmd"; then
            continue
        fi

        # Detect package install commands
        if [[ "$cmd" =~ apt-get[[:space:]]+install ]]; then
            _extract_apt_packages "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ apt[[:space:]]+install ]]; then
            _extract_apt_packages "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ apk[[:space:]]+add ]]; then
            _extract_apk_packages "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ (yum|dnf)[[:space:]]+install ]]; then
            _extract_yum_packages "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ pip[[:space:]]+install || "$cmd" =~ pip3[[:space:]]+install ]]; then
            _extract_pip_install "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ uv[[:space:]]+pip[[:space:]]+install ]]; then
            _extract_pip_install "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ npm[[:space:]]+(i|install)[[:space:]]+-g ]]; then
            _extract_npm_global "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ mkdir[[:space:]]+-p ]]; then
            _extract_mkdir "$cmd" "$ir_file" "$line_num"
        elif [[ "$cmd" =~ python.*-m[[:space:]]+venv || "$cmd" =~ virtualenv ]]; then
            _extract_venv "$cmd" "$ir_file" "$line_num"
        else
            # Generic RUN command - check if it's setup-like
            _extract_generic_run "$cmd" "$ir_file" "$line_num"
        fi
    done
}

_split_run_commands() {
    local body="$1"
    local -n _out_commands="$2"
    # Split on ' && ' by replacing it with a delimiter, then splitting
    local delim=$'\x1f'  # unit separator
    local replaced="${body// && /$delim}"
    # Also handle '&&' without spaces
    replaced="${replaced//&&/$delim}"
    IFS="$delim" read -ra _out_commands <<< "$replaced"
}

_extract_apt_packages() {
    local cmd="$1" ir_file="$2" line_num="$3"

    # Strip everything up to and including 'install'
    local pkg_list
    pkg_list=$(echo "$cmd" | sed -E 's/.*install\s+//')

    # Extract package names (skip flags starting with -)
    local pkg
    for pkg in $pkg_list; do
        # Skip flags
        [[ "$pkg" == -* ]] && continue
        # Skip version specifiers
        [[ "$pkg" == *"="* ]] && pkg="${pkg%%=*}"
        # Skip empty
        [[ -z "$pkg" ]] && continue

        map_package "apt" "$pkg" "$ir_file" "$line_num"
    done
}

_extract_apk_packages() {
    local cmd="$1" ir_file="$2" line_num="$3"

    local pkg_list
    pkg_list=$(echo "$cmd" | sed -E 's/.*add\s+//')

    local pkg
    for pkg in $pkg_list; do
        [[ "$pkg" == -* ]] && continue
        [[ -z "$pkg" ]] && continue
        map_package "apk" "$pkg" "$ir_file" "$line_num"
    done
}

_extract_yum_packages() {
    local cmd="$1" ir_file="$2" line_num="$3"

    local pkg_list
    pkg_list=$(echo "$cmd" | sed -E 's/.*(yum|dnf)\s+install\s+//')

    local pkg
    for pkg in $pkg_list; do
        [[ "$pkg" == -* ]] && continue
        [[ -z "$pkg" ]] && continue
        map_package "apt" "$pkg" "$ir_file" "$line_num"  # yum names are close to apt
    done
}

_extract_pip_install() {
    local cmd="$1" ir_file="$2" line_num="$3"
    local map_file="$DOCK2FLOX_DATA/pip_to_nixpkgs.map"

    # Extract package names: strip the command prefix, flags, and version specifiers
    local pkg_list
    pkg_list=$(echo "$cmd" | sed -E '
        s/.*pip[3]?\s+install\s+//
        s/--[a-z][-a-z]*(=[^ ]+)?//g
        s/-[a-zA-Z]( [^ ]+)?//g
        s/-r [^ ]+//g
    ')

    local -a unmapped_pkgs=()
    local pkg nixpkgs_path

    for pkg in $pkg_list; do
        # Skip empty, flags, paths, URLs, VCS refs
        [[ -z "$pkg" ]] && continue
        [[ "$pkg" == -* ]] && continue
        [[ "$pkg" == .* || "$pkg" == /* ]] && continue
        [[ "$pkg" == http* ]] && continue
        [[ "$pkg" == git+* ]] && continue
        [[ "$pkg" == git@* ]] && continue
        [[ "$pkg" == file:* ]] && continue
        [[ "$pkg" == ssh:* ]] && continue

        # Strip surrounding quotes
        pkg="${pkg#\"}"
        pkg="${pkg%\"}"
        pkg="${pkg#\'}"
        pkg="${pkg%\'}"

        # Strip version specifiers (>=, <=, ~=, ==, [extras])
        pkg=$(echo "$pkg" | sed -E 's/[><=~!]=?.*//; s/\[.*\]//')
        [[ -z "$pkg" ]] && continue

        # Look up in pip_to_nixpkgs.map
        nixpkgs_path=""
        if [[ -f "$map_file" ]]; then
            nixpkgs_path=$(awk -F'\t' -v p="$pkg" 'tolower($1) == tolower(p) {print $2; exit}' "$map_file")
        fi

        if [[ "$nixpkgs_path" == "_skip_" ]]; then
            log_verbose "pip: skipping $pkg (included with python)"
            continue
        elif [[ -n "$nixpkgs_path" ]]; then
            local install_id
            if [[ "$nixpkgs_path" == *.* ]]; then
                install_id="${nixpkgs_path##*.}"
            else
                install_id="$nixpkgs_path"
            fi
            ir_install "$ir_file" "$install_id" "$nixpkgs_path" "" "" "EXACT" "$line_num" "from pip install"
            log_verbose "pip: $pkg -> $nixpkgs_path (EXACT)"
        else
            unmapped_pkgs+=("$pkg")
            log_verbose "pip: $pkg -> unmapped (will remain as hook)"
        fi
    done

    # Emit remaining unmapped packages as a uv pip install hook
    if [[ ${#unmapped_pkgs[@]} -gt 0 ]]; then
        local remaining="${unmapped_pkgs[*]}"
        ir_hook "$ir_file" "100" "# pip packages not in Flox catalog (install manually):" "$line_num"
        ir_hook "$ir_file" "101" "# uv pip install $remaining" "$line_num"
    fi
}

_extract_npm_global() {
    local cmd="$1" ir_file="$2" line_num="$3"
    local map_file="$DOCK2FLOX_DATA/npm_to_nixpkgs.map"

    # Extract package names after -g flag
    local pkg_list
    pkg_list=$(echo "$cmd" | sed -E 's/.*install\s+-g\s+//' | sed -E 's/--[a-z-]+(=[^ ]+)?//g')

    local -a unmapped_pkgs=()
    local pkg nixpkgs_path

    for pkg in $pkg_list; do
        [[ -z "$pkg" ]] && continue
        [[ "$pkg" == -* ]] && continue

        # Strip version specifier (@version) — handle scoped packages (@scope/name@ver)
        if [[ "$pkg" == @*/* ]]; then
            # Scoped package: @scope/name@version -> @scope/name
            pkg=$(echo "$pkg" | sed -E 's/(@[^/]+\/[^@]+)@.*/\1/')
        else
            # Regular package: name@version -> name
            pkg="${pkg%%@*}"
        fi
        [[ -z "$pkg" ]] && continue

        # Look up in npm_to_nixpkgs.map
        nixpkgs_path=""
        if [[ -f "$map_file" ]]; then
            nixpkgs_path=$(awk -F'\t' -v p="$pkg" '$1 == p {print $2; exit}' "$map_file")
        fi

        if [[ "$nixpkgs_path" == "_skip_" ]]; then
            log_verbose "npm: skipping $pkg"
            continue
        elif [[ -n "$nixpkgs_path" ]]; then
            local install_id
            if [[ "$nixpkgs_path" == *.* ]]; then
                install_id="${nixpkgs_path##*.}"
            else
                install_id="$nixpkgs_path"
            fi
            ir_install "$ir_file" "$install_id" "$nixpkgs_path" "" "" "EXACT" "$line_num" "from npm install -g"
            log_verbose "npm: $pkg -> $nixpkgs_path (EXACT)"
        else
            unmapped_pkgs+=("$pkg")
            log_verbose "npm: $pkg -> unmapped"
        fi
    done

    # Emit remaining as hook
    if [[ ${#unmapped_pkgs[@]} -gt 0 ]]; then
        local remaining="${unmapped_pkgs[*]}"
        ir_hook "$ir_file" "100" "# npm globals not in Flox catalog:" "$line_num"
        ir_hook "$ir_file" "101" "# npm install -g $remaining" "$line_num"
    fi
}

# --- Known installer pattern detection ---

_detect_known_installer() {
    local run_body="$1" ir_file="$2" line_num="$3"
    local map_file="$DOCK2FLOX_DATA/known_installers.map"

    [[ ! -f "$map_file" ]] && return 1

    local pattern tool_name pkg_path
    while IFS=$'\t' read -r pattern tool_name pkg_path; do
        # Skip comments and empty lines
        [[ -z "$pattern" || "$pattern" == "#"* ]] && continue

        # Check if the full RUN body contains this URL pattern
        if [[ "$run_body" == *"$pattern"* ]]; then
            log_verbose "Known installer detected: $tool_name (pattern: $pattern)"
            ir_install "$ir_file" "$tool_name" "$pkg_path" "" "" "EXACT" "$line_num" "detected installer script for $tool_name"
            return 0
        fi
    done < "$map_file"

    return 1
}

_extract_mkdir() {
    local cmd="$1" ir_file="$2" line_num="$3"
    # mkdir -p -> hook if it's a workspace dir setup
    local dirs
    dirs=$(echo "$cmd" | sed -E 's/mkdir\s+-p\s+//')
    # Skip absolute paths that are OCI-specific (/app, /usr/src, etc.)
    local dir
    for dir in $dirs; do
        case "$dir" in
            /app|/app/*|/usr/src/*|/opt/*)
                ir_skip "$ir_file" "mkdir $dir" "container-specific path" "$line_num"
                ;;
            *)
                ir_hook "$ir_file" "030" "mkdir -p \"$dir\"" "$line_num"
                ;;
        esac
    done
}

_extract_venv() {
    local cmd="$1" ir_file="$2" line_num="$3"
    # Python venv creation -> standard Flox hook pattern
    ir_hook "$ir_file" "040" 'export VIRTUAL_ENV="$FLOX_ENV_CACHE/venv"' "$line_num"
    ir_hook "$ir_file" "041" 'if [ ! -d "$VIRTUAL_ENV" ]; then' "$line_num"
    ir_hook "$ir_file" "042" '  uv venv "$VIRTUAL_ENV" --python python3' "$line_num"
    ir_hook "$ir_file" "043" 'fi' "$line_num"
    ir_hook "$ir_file" "044" 'export PATH="$VIRTUAL_ENV/bin:$PATH"' "$line_num"
}

_extract_generic_run() {
    local cmd="$1" ir_file="$2" line_num="$3"
    # For unrecognized RUN commands, emit as a commented hook line
    ir_hook "$ir_file" "200" "# RUN: $cmd" "$line_num"
}

_parse_expose() {
    local line="$1" ir_file="$2" line_num="$3"
    # EXPOSE -> extract port as informational
    local ports
    ports=$(echo "$line" | sed -E 's/^EXPOSE\s+//i')
    ir_skip "$ir_file" "EXPOSE $ports" "container networking" "$line_num"
    # But note the port as potentially useful for [vars]
    local port
    for port in $ports; do
        port="${port%%/*}" # strip /tcp, /udp
        log_verbose "Noted exposed port: $port (line $line_num)"
    done
}

# --- Skip pattern matching ---

_should_skip_env() {
    local line="$1"
    local pattern_file="$DOCK2FLOX_DATA/skip_patterns.list"
    [[ ! -f "$pattern_file" ]] && return 1

    local pattern
    while IFS= read -r pattern; do
        [[ -z "$pattern" || "$pattern" == "#"* ]] && continue
        [[ "$pattern" != ENV:* ]] && continue
        local env_name="${pattern#ENV:}"
        if [[ "$line" == *"$env_name"* ]]; then
            return 0
        fi
    done < "$pattern_file"
    return 1
}

_should_skip_run() {
    local cmd="$1"
    local pattern_file="$DOCK2FLOX_DATA/skip_patterns.list"
    [[ ! -f "$pattern_file" ]] && return 1

    local pattern
    while IFS= read -r pattern; do
        [[ -z "$pattern" || "$pattern" == "#"* ]] && continue
        [[ "$pattern" != RUN:* ]] && continue
        local run_pattern="${pattern#RUN:}"
        if [[ "$cmd" == *"$run_pattern"* ]]; then
            return 0
        fi
    done < "$pattern_file"
    return 1
}
