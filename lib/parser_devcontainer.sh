#!/usr/bin/env bash
# dock2flox devcontainer.json parser
# Calls the Python parser and handles dockerComposeFile chaining.

# Requires: lib/core.sh sourced first

parse_devcontainer() {
    local devcontainer_file="$1"
    local ir_file="$2"

    if [[ ! -f "$devcontainer_file" ]]; then
        log_error "Devcontainer file not found: $devcontainer_file"
        return 1
    fi

    log_info "Parsing: $devcontainer_file"

    local parsed=0
    if command -v python3 >/dev/null 2>&1 && [[ -f "$DOCK2FLOX_ROOT/lib/parser_devcontainer.py" ]]; then
        local parsed_ir
        parsed_ir=$(dock2flox_mktemp)
        if python3 "$DOCK2FLOX_ROOT/lib/parser_devcontainer.py" "$devcontainer_file" > "$parsed_ir"; then
            cat "$parsed_ir" >> "$ir_file"
            parsed=1
            # Re-process lifecycle commands (order 060-090) through the RUN interpreter
            # to apply pip calculus, package detection, etc.
            _reprocess_lifecycle_hooks "$ir_file"
        else
            log_warn "Devcontainer parser failed"
        fi
    else
        log_warn "python3 not available for devcontainer parsing"
    fi

    if [[ "$parsed" -eq 0 ]]; then
        ir_review "$ir_file" "devcontainer-parser" "devcontainer.json could not be parsed; review manually" "0"
        return 0
    fi

    # If dockerComposeFile is referenced, chain to compose parser
    local compose_ref compose_service
    compose_ref=$(python3 -c "
import json, re, sys
text = open('$devcontainer_file').read()
text = re.sub(r'//.*$', '', text, flags=re.MULTILINE)
text = re.sub(r',\s*([}\]])', r'\1', text)
c = json.loads(text)
dcf = c.get('dockerComposeFile', '')
if isinstance(dcf, list): dcf = dcf[0] if dcf else ''
print(dcf)
" 2>/dev/null || true)
    compose_service=$(python3 -c "
import json, re, sys
text = open('$devcontainer_file').read()
text = re.sub(r'//.*$', '', text, flags=re.MULTILINE)
text = re.sub(r',\s*([}\]])', r'\1', text)
c = json.loads(text)
print(c.get('service', ''))
" 2>/dev/null || true)

    # If build.dockerfile is referenced, chain to Dockerfile parser
    local build_context build_dockerfile
    build_context=$(python3 -c "
import json, re, sys
text = open('$devcontainer_file').read()
text = re.sub(r'//.*$', '', text, flags=re.MULTILINE)
text = re.sub(r',\s*([}\]])', r'\1', text)
c = json.loads(text)
b = c.get('build')
if b is None: pass
elif isinstance(b, str) and b: print(b)
elif isinstance(b, dict): print(b.get('context', '.'))
" 2>/dev/null || true)
    build_dockerfile=$(python3 -c "
import json, re, sys
text = open('$devcontainer_file').read()
text = re.sub(r'//.*$', '', text, flags=re.MULTILINE)
text = re.sub(r',\s*([}\]])', r'\1', text)
c = json.loads(text)
b = c.get('build')
if b is None: pass
elif isinstance(b, str): print('Dockerfile')
elif isinstance(b, dict): print(b.get('dockerfile', 'Dockerfile'))
" 2>/dev/null || true)

    if [[ -n "$build_dockerfile" ]]; then
        local devcontainer_dir
        devcontainer_dir=$(dirname "$devcontainer_file")
        # dockerfile is relative to context; context is relative to devcontainer.json dir
        local context_path="$devcontainer_dir/${build_context:-.}"
        local dockerfile_path="$context_path/$build_dockerfile"
        if [[ -f "$dockerfile_path" ]] && declare -f parse_dockerfile > /dev/null 2>&1; then
            log_info "Chaining to Dockerfile parser for: $dockerfile_path"
            parse_dockerfile "$dockerfile_path" "$ir_file"
        elif [[ -n "$build_context" || -n "$build_dockerfile" ]]; then
            ir_review "$ir_file" "devcontainer-build" \
                "build references $build_dockerfile (context: ${build_context:-.}) but file not found at $dockerfile_path" "0"
        fi
    fi

    if [[ -n "$compose_ref" ]]; then
        local compose_dir
        compose_dir=$(dirname "$devcontainer_file")
        local compose_path="$compose_dir/$compose_ref"
        if [[ -f "$compose_path" ]] && declare -f parse_compose > /dev/null 2>&1; then
            log_info "Chaining to Compose parser for: $compose_path (service: ${compose_service:-all})"
            parse_compose "$compose_path" "$ir_file"
        else
            ir_review "$ir_file" "devcontainer-compose" \
                "dockerComposeFile references $compose_ref (service: ${compose_service:-unspecified}) but file not found at $compose_path" "0"
        fi
        if [[ -n "$compose_service" ]]; then
            ir_var "$ir_file" "DOCK2FLOX_DEVCONTAINER_SERVICE" "$compose_service" "0"
        fi
    fi
}

_reprocess_lifecycle_hooks() {
    local ir_file="$1"

    # Check if _parse_run is available (requires parser_dockerfile.sh to be sourced)
    if ! declare -f _parse_run > /dev/null 2>&1; then
        return 0
    fi

    # Set up minimal scope for _parse_run
    local -A arg_table=()
    local -A env_table=()
    local pkg_manager="apt"
    local current_arch="x86_64"
    local current_shell_kind="bash"
    local current_shell_explicit=0

    # Extract lifecycle HOOK records (orders 060-090)
    local lifecycle_hooks
    lifecycle_hooks=$({ grep "^HOOK${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | awk -F "$IR_DELIM" '$2 >= 60 && $2 <= 90')

    [[ -z "$lifecycle_hooks" ]] && return 0

    # Remove original lifecycle hooks from IR
    local cleaned
    cleaned=$(dock2flox_mktemp)
    { grep -v "^HOOK${IR_DELIM}" "$ir_file" 2>/dev/null || true; } > "$cleaned"
    # Keep non-lifecycle hooks (orders outside 060-090)
    { grep "^HOOK${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | awk -F "$IR_DELIM" '$2 < 60 || $2 > 90' >> "$cleaned"
    cp "$cleaned" "$ir_file"

    # Re-process each lifecycle command through _parse_run
    while IFS="$IR_DELIM" read -r _ order cmd line_num; do
        cmd=$(_ir_decode "$cmd")
        [[ -z "$cmd" ]] && continue

        # Capture what _parse_run produces in a temp IR
        local temp_ir
        temp_ir=$(dock2flox_mktemp)
        _parse_run "RUN $cmd" "$temp_ir" "${line_num:-0}"

        # Merge _parse_run results, but convert "# RUN: ..." comments back to
        # live hook commands — in devcontainer context, unrecognized commands
        # are still valid lifecycle steps (e.g., "uv sync"), not dead code.
        if [[ -s "$temp_ir" ]]; then
            # Convert commented-out RUN hooks to live hooks
            while IFS="$IR_DELIM" read -r rec_type rec_order rec_cmd rec_line; do
                rec_cmd=$(_ir_decode "$rec_cmd")
                if [[ "$rec_type" == "HOOK" && "$rec_cmd" == "# RUN: "* ]]; then
                    # Strip "# RUN: " prefix, emit as live hook
                    local live_cmd="${rec_cmd#\# RUN: }"
                    ir_hook "$ir_file" "$rec_order" "$live_cmd" "$rec_line"
                else
                    # Pass through as-is (INSTALL, HOOK, REVIEW, etc.)
                    printf '%s\n' "$rec_type${IR_DELIM}$rec_order${IR_DELIM}$(_ir_encode "$rec_cmd")${IR_DELIM}$rec_line" >> "$ir_file"
                fi
            done < "$temp_ir"
            log_verbose "Lifecycle command reprocessed: $cmd"
        else
            # Empty result — keep original command as a live hook
            ir_hook "$ir_file" "$order" "$cmd" "${line_num:-0}"
            log_verbose "Lifecycle command preserved as hook: $cmd"
        fi
    done <<< "$lifecycle_hooks"
}
