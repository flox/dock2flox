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
