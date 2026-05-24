#!/usr/bin/env bash
# dock2flox core library — logging, temp file management, TTY detection, shared utilities

set -euo pipefail

# --- Constants ---
readonly DOCK2FLOX_VERSION="0.1.0"
readonly DOCK2FLOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DOCK2FLOX_LIB="$DOCK2FLOX_ROOT/lib"
readonly DOCK2FLOX_DATA="$DOCK2FLOX_ROOT/data"

# --- TTY Detection ---
dock2flox_is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# --- Logging ---
_log() {
    local level="$1" msg="$2"
    printf '[dock2flox] %s: %s\n' "$level" "$msg" >&2
}

log_info() { _log "info" "$1"; }
log_warn() { _log "warn" "$1"; }
log_error() { _log "error" "$1"; }
log_verbose() {
    if [[ "${DOCK2FLOX_VERBOSE:-0}" == "1" ]]; then
        _log "debug" "$1"
    fi
}

# --- Temp File Management ---
declare -a _DOCK2FLOX_TMPFILES=()

dock2flox_mktemp() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/dock2flox.XXXXXX")
    _DOCK2FLOX_TMPFILES+=("$tmp")
    printf '%s' "$tmp"
}

dock2flox_cleanup() {
    local f
    for f in "${_DOCK2FLOX_TMPFILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    _DOCK2FLOX_TMPFILES=()
}

trap dock2flox_cleanup EXIT

# --- IR Record Helpers ---
# The IR format uses unit separator (0x1f) as field delimiter to avoid
# conflicts with pipe characters that commonly appear in shell commands and URLs.
readonly IR_DELIM=$'\x1f'

# Encode a value for safe IR storage (escape newlines)
_ir_encode() {
    local val="$1"
    # Escape backslashes first, then newlines
    val="${val//\\/\\\\}"
    val="${val//$'\n'/\\n}"
    printf '%s' "$val"
}

# Decode an IR-encoded value
_ir_decode() {
    local val="$1"
    # Unescape newlines, then backslashes
    val="${val//\\n/$'\n'}"
    val="${val//\\\\/\\}"
    printf '%s' "$val"
}

# Write an INSTALL record to the IR file
ir_install() {
    local ir_file="$1" id="$2" pkg_path="$3" version="${4:-}" pkg_group="${5:-}" confidence="${6:-EXACT}" line_num="${7:-0}" notes="${8:-}"
    printf 'INSTALL%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
        "$IR_DELIM" "$id" "$IR_DELIM" "$pkg_path" "$IR_DELIM" "$version" \
        "$IR_DELIM" "$pkg_group" "$IR_DELIM" "$confidence" "$IR_DELIM" "$line_num" \
        "$IR_DELIM" "$(_ir_encode "$notes")" >> "$ir_file"
}

# Write a VAR record to the IR file
ir_var() {
    local ir_file="$1" name="$2" value="$3" line_num="${4:-0}"
    printf 'VAR%s%s%s%s%s%s\n' \
        "$IR_DELIM" "$name" "$IR_DELIM" "$(_ir_encode "$value")" "$IR_DELIM" "$line_num" >> "$ir_file"
}

# Write a HOOK record to the IR file
ir_hook() {
    local ir_file="$1" order="$2" bash_line="$3" line_num="${4:-0}"
    printf 'HOOK%s%s%s%s%s%s\n' \
        "$IR_DELIM" "$order" "$IR_DELIM" "$(_ir_encode "$bash_line")" "$IR_DELIM" "$line_num" >> "$ir_file"
}

# Write a SERVICE record to the IR file
ir_service() {
    local ir_file="$1" name="$2" command="$3" line_num="${4:-0}"
    printf 'SERVICE%s%s%s%s%s%s\n' \
        "$IR_DELIM" "$name" "$IR_DELIM" "$(_ir_encode "$command")" "$IR_DELIM" "$line_num" >> "$ir_file"
}

# Write a SKIP record to the IR file
ir_skip() {
    local ir_file="$1" instruction="$2" reason="$3" line_num="${4:-0}"
    printf 'SKIP%s%s%s%s%s%s\n' \
        "$IR_DELIM" "$(_ir_encode "$instruction")" "$IR_DELIM" "$(_ir_encode "$reason")" "$IR_DELIM" "$line_num" >> "$ir_file"
}

# --- File Auto-Detection ---
dock2flox_detect_inputs() {
    local dir="${1:-.}"
    local -a found=()

    # Dockerfiles
    for f in "$dir"/Dockerfile "$dir"/Dockerfile.* "$dir"/*.dockerfile; do
        [[ -f "$f" ]] && found+=("$f")
    done

    # Compose files
    for f in "$dir"/docker-compose.yml "$dir"/docker-compose.yaml "$dir"/compose.yml "$dir"/compose.yaml; do
        [[ -f "$f" ]] && found+=("$f")
    done

    printf '%s\n' "${found[@]}"
}

# --- Input Type Classification ---
dock2flox_classify_input() {
    local filepath="$1"
    local basename
    basename=$(basename "$filepath")

    case "$basename" in
        Dockerfile|Dockerfile.*|*.dockerfile)
            printf 'dockerfile'
            ;;
        docker-compose*.yml|docker-compose*.yaml|compose*.yml|compose*.yaml)
            printf 'compose'
            ;;
        devcontainer.json)
            printf 'devcontainer'
            ;;
        *)
            # Fallback: check file content for Dockerfile-like instructions
            if head -5 "$filepath" 2>/dev/null | grep -qi '^\(FROM\|ARG\|ENV\|RUN\) '; then
                printf 'dockerfile'
            elif head -5 "$filepath" 2>/dev/null | grep -qi '^services:'; then
                printf 'compose'
            else
                printf 'unknown'
            fi
            ;;
    esac
}

# --- Interactive Prompting ---
dock2flox_prompt_yesno() {
    local question="$1" default="${2:-y}"
    if ! dock2flox_is_interactive; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    local reply
    printf '%s [%s] ' "$question" "$default" >&2
    read -r reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

dock2flox_prompt_choice() {
    local question="$1"
    shift
    local -a options=("$@")

    if ! dock2flox_is_interactive; then
        printf '%s' "${options[0]}"
        return 0
    fi

    printf '%s\n' "$question" >&2
    local i
    for i in "${!options[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${options[$i]}" >&2
    done
    local reply
    printf 'Choice [1]: ' >&2
    read -r reply
    reply="${reply:-1}"
    printf '%s' "${options[$((reply - 1))]}"
}
