#!/usr/bin/env bash
# dock2flox TOML emitter
# Reads the intermediate representation and produces a valid manifest.toml

# Requires: lib/core.sh sourced first

emit_toml() {
    local ir_file="$1"

    # Infer cache hooks based on detected packages (before emitting)
    _infer_cache_hooks "$ir_file"

    _emit_header
    _emit_review_comments "$ir_file"
    _emit_install_section "$ir_file"
    _emit_vars_section "$ir_file"
    _emit_hook_section "$ir_file"
    _emit_services_section "$ir_file"
    _emit_options_section
}

# --- TOML escaping ---

# Escape a value for use in a TOML basic string (double-quoted)
_toml_escape() {
    local value="$1"
    # Must escape backslashes first, then other chars
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    # If value contains newlines, caller should use multi-line literal instead
    printf '%s' "$value"
}

# --- Cache hook inference ---

_infer_cache_hooks() {
    local ir_file="$1"
    local cache_map="$DOCK2FLOX_DATA/cache_hooks.map"

    [[ ! -f "$cache_map" ]] && return 0

    # Detect which ecosystems are present in INSTALL records. Cache hooks are
    # inferred once immediately before rendering, so do not skip just because a
    # lifecycle hook mentions FLOX_ENV_CACHE (for example Bundler path setup).

    # Detect which ecosystems are present in INSTALL records
    local installs
    installs=$({ grep "^INSTALL${IR_DELIM}" "$ir_file" 2>/dev/null || true; })
    [[ -z "$installs" ]] && return 0

    local -A ecosystems_detected=()

    # Check for python
    if echo "$installs" | grep -q "python"; then
        ecosystems_detected[python]=1
    fi
    # Check for nodejs
    if echo "$installs" | grep -q "nodejs\|node"; then
        ecosystems_detected[nodejs]=1
    fi
    # Check for rust
    if echo "$installs" | grep -q "rustc\|cargo"; then
        ecosystems_detected[rust]=1
    fi
    # Check for go (exact match using delimiters to avoid matching "mongo", "golang" etc.)
    if echo "$installs" | grep -q "${IR_DELIM}go${IR_DELIM}"; then
        ecosystems_detected[go]=1
    fi
    if echo "$installs" | grep -q "yarn-berry\|${IR_DELIM}yarn${IR_DELIM}"; then
        ecosystems_detected[yarn]=1
    fi
    if echo "$installs" | grep -q "nodePackages.pnpm\|${IR_DELIM}pnpm${IR_DELIM}"; then
        ecosystems_detected[pnpm]=1
    fi
    if echo "$installs" | grep -q "${IR_DELIM}ruby${IR_DELIM}"; then
        ecosystems_detected[ruby]=1
    fi
    if echo "$installs" | grep -q "${IR_DELIM}bundler${IR_DELIM}"; then
        ecosystems_detected[bundler]=1
    fi
    if echo "$installs" | grep -q "phpPackages.composer\|${IR_DELIM}composer${IR_DELIM}"; then
        ecosystems_detected[composer]=1
    fi
    if echo "$installs" | grep -q "${IR_DELIM}maven${IR_DELIM}"; then
        ecosystems_detected[maven]=1
    fi
    if echo "$installs" | grep -q "${IR_DELIM}gradle${IR_DELIM}"; then
        ecosystems_detected[gradle]=1
    fi

    [[ ${#ecosystems_detected[@]} -eq 0 ]] && return 0

    # Collect cache export lines for detected ecosystems
    local -a cache_exports=()
    local -a cache_dirs=()

    # Collect existing hook and var variable names to avoid overwriting user values
    local existing_vars
    existing_vars=$({ grep "^HOOK${IR_DELIM}\|^VAR${IR_DELIM}" "$ir_file" 2>/dev/null || true; })

    local ecosystem export_line
    while IFS=$'\t' read -r ecosystem export_line; do
        [[ -z "$ecosystem" || "$ecosystem" == "#"* ]] && continue
        if [[ -n "${ecosystems_detected[$ecosystem]:-}" ]]; then
            # Extract variable name from "export VAR_NAME=..."
            local var_name
            var_name=$(echo "$export_line" | sed -E 's/^export ([A-Za-z_][A-Za-z0-9_]*)=.*/\1/')

            # Skip if already set by a parsed hook or var — user's value takes precedence
            if echo "$existing_vars" | grep -q "$var_name=\|${IR_DELIM}${var_name}${IR_DELIM}"; then
                log_verbose "Cache hook skipped: $var_name already set by parsed input"
                continue
            fi

            cache_exports+=("$export_line")
            # Extract dir path for mkdir
            local dir_path
            dir_path=$(echo "$export_line" | sed -E 's/.*="([^"]+)".*/\1/')
            cache_dirs+=("$dir_path")
        fi
    done < "$cache_map"

    [[ ${#cache_exports[@]} -eq 0 ]] && return 0

    # Inject cache hooks at priority 010-019 (before any user hooks)
    local i=10
    for export_line in "${cache_exports[@]}"; do
        ir_hook "$ir_file" "$(printf '%03d' $i)" "$export_line" "0"
        i=$((i + 1))
    done

    # Add mkdir -p for all cache dirs
    local mkdir_line="mkdir -p"
    for dir in "${cache_dirs[@]}"; do
        mkdir_line+=" \"$dir\""
    done
    ir_hook "$ir_file" "$(printf '%03d' $i)" "$mkdir_line" "0"

    log_verbose "Injected cache hooks for: ${!ecosystems_detected[*]}"
}

_dedup_cuda_provides() {
    local deduped="$1"
    local cuda_map="$DOCK2FLOX_DATA/cuda_packages.map"
    [[ ! -f "$cuda_map" ]] && return 0

    # Build list of packages that are transitively provided by other installed CUDA packages
    local -a to_remove=()
    local provider path provides provided_pkg
    while IFS=$'\t' read -r provider path provides; do
        [[ -z "$provider" || "$provider" == "#"* ]] && continue
        [[ -z "$provides" ]] && continue
        # If the provider is in the deduped install list
        if grep -q "${IR_DELIM}${path}${IR_DELIM}" "$deduped" 2>/dev/null; then
            # Mark each provided package for removal
            for provided_pkg in $provides; do
                local provided_path
                provided_path=$(awk -F'\t' -v p="$provided_pkg" 'tolower($1) == tolower(p) && $1 !~ /^#/ {print $2; exit}' "$cuda_map")
                if [[ -n "$provided_path" ]]; then
                    to_remove+=("$provided_path")
                fi
            done
        fi
    done < "$cuda_map"

    # Remove transitively-provided packages from deduped
    if [[ ${#to_remove[@]} -gt 0 ]]; then
        local filtered
        filtered=$(dock2flox_mktemp)
        local pkg_path line_match
        while IFS= read -r line_match; do
            local should_remove=0
            for pkg_path in "${to_remove[@]}"; do
                if [[ "$line_match" == *"${IR_DELIM}${pkg_path}${IR_DELIM}"* ]]; then
                    should_remove=1
                    break
                fi
            done
            [[ "$should_remove" -eq 0 ]] && printf '%s\n' "$line_match"
        done < "$deduped" > "$filtered"
        cp "$filtered" "$deduped"
    fi
}

_load_conflict_priorities() {
    local deduped="$1" priorities_file="$2"
    local conflict_map="$DOCK2FLOX_DATA/package_conflicts.map"

    [[ ! -f "$conflict_map" ]] && return 0
    [[ ! -s "$deduped" ]] && return 0

    local installed_ids
    installed_ids=$(dock2flox_mktemp)
    cut -d "$IR_DELIM" -f2 "$deduped" | sort -u > "$installed_ids"

    local winner loser conflict_path winner_priority loser_priority notes
    while IFS=$'\t' read -r winner loser conflict_path winner_priority loser_priority notes; do
        [[ -z "$winner" || "$winner" == "#"* ]] && continue
        [[ -z "$loser" || -z "$winner_priority" || -z "$loser_priority" ]] && continue

        if grep -qxF "$winner" "$installed_ids" && grep -qxF "$loser" "$installed_ids"; then
            local note
            note="conflict: ${notes:-$winner and $loser both provide $conflict_path}; priorities set automatically"
            printf '%s\t%s\t%s\n' "$winner" "$winner_priority" "$note" >> "$priorities_file"
            printf '%s\t%s\t%s\n' "$loser" "$loser_priority" "$note" >> "$priorities_file"
        fi
    done < "$conflict_map"
}

_priority_for_install() {
    local priorities_file="$1" install_id="$2"
    [[ ! -s "$priorities_file" ]] && return 0
    awk -F'\t' -v id="$install_id" '$1 == id && !found { print $2; found=1 }' "$priorities_file"
}

_priority_note_for_install() {
    local priorities_file="$1" install_id="$2"
    [[ ! -s "$priorities_file" ]] && return 0
    awk -F'\t' -v id="$install_id" '$1 == id && !found { print $3; found=1 }' "$priorities_file"
}


_emit_review_comments() {
    local ir_file="$1"

    local reviews
    reviews=$({ grep "^REVIEW${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | sort -t "$IR_DELIM" -k4,4n | awk '!seen[$0]++')
    [[ -z "$reviews" ]] && return 0

    printf '# Review notes from dock2flox analysis:\n'
    while IFS="$IR_DELIM" read -r _ category detail line_num; do
        category=$(_ir_decode "$category")
        detail=$(_ir_decode "$detail")
        printf '# REVIEW[%s] line %s: %s\n' "$category" "$line_num" "$detail"
    done <<< "$reviews"
    printf '\n'
}

# --- Section emitters ---

_emit_header() {
    cat <<'EOF'
# Generated by dock2flox — https://github.com/flox/dock2flox
# Review all entries marked with REVIEW or UNMAPPED before activating.
# Flox manifest version managed by Flox CLI
schema-version = "1.11.0"

EOF
}

_emit_install_section() {
    local ir_file="$1"

    # Collect INSTALL records, deduplicate by install_id (keep highest confidence)
    local deduped
    deduped=$(dock2flox_mktemp)

    # Sort by install_id, then by confidence (EXACT > HIGH > LOW > UNMAPPED)
    { grep "^INSTALL${IR_DELIM}" "$ir_file" 2>/dev/null || true; } \
        | sort -t "$IR_DELIM" -k2,2 -k6,6 \
        | awk -F "$IR_DELIM" '!seen[$2]++' > "$deduped"

    # CUDA dedup: if torchvision is present, remove standalone torch (it's transitive)
    _dedup_cuda_provides "$deduped"

    if [[ ! -s "$deduped" ]]; then
        printf '[install]\n\n'
        return 0
    fi

    local priorities
    priorities=$(dock2flox_mktemp)
    _load_conflict_priorities "$deduped" "$priorities"

    printf '[install]\n'

    while IFS="$IR_DELIM" read -r _ install_id pkg_path version pkg_group confidence line_num notes; do
        notes=$(_ir_decode "$notes")

        local priority priority_note
        priority=$(_priority_for_install "$priorities" "$install_id")
        priority_note=$(_priority_note_for_install "$priorities" "$install_id")

        # Emit confidence-based comments for non-EXACT entries.
        case "$confidence" in
            UNMAPPED)
                printf '# UNMAPPED: %s (line %s) — verify with: flox search %s\n' \
                    "${notes:-$pkg_path}" "$line_num" "$pkg_path"
                printf '# %s.pkg-path = "%s"\n' "$install_id" "$(_toml_escape "$pkg_path")"
                ;;
            LOW)
                printf '# REVIEW: %s (line %s)\n' "${notes:-$pkg_path}" "$line_num"
                [[ -n "$priority_note" ]] && printf '# %s\n' "$priority_note"
                printf '%s.pkg-path = "%s"\n' "$install_id" "$(_toml_escape "$pkg_path")"
                [[ -n "$version" ]] && printf '%s.version = "%s"\n' "$install_id" "$(_toml_escape "$version")"
                [[ -n "$pkg_group" ]] && printf '%s.pkg-group = "%s"\n' "$install_id" "$(_toml_escape "$pkg_group")"
                [[ -n "$priority" ]] && printf '%s.priority = %s\n' "$install_id" "$priority"
                ;;
            HIGH)
                if [[ -n "$notes" ]]; then
                    printf '# %s\n' "$notes"
                fi
                [[ -n "$priority_note" ]] && printf '# %s\n' "$priority_note"
                printf '%s.pkg-path = "%s"\n' "$install_id" "$(_toml_escape "$pkg_path")"
                [[ -n "$version" ]] && printf '%s.version = "%s"\n' "$install_id" "$(_toml_escape "$version")"
                [[ -n "$pkg_group" ]] && printf '%s.pkg-group = "%s"\n' "$install_id" "$(_toml_escape "$pkg_group")"
                [[ -n "$priority" ]] && printf '%s.priority = %s\n' "$install_id" "$priority"
                ;;
            EXACT|*)
                if [[ -n "$notes" && "$notes" != "from base image"* ]]; then
                    printf '# %s\n' "$notes"
                fi
                [[ -n "$priority_note" ]] && printf '# %s\n' "$priority_note"
                printf '%s.pkg-path = "%s"\n' "$install_id" "$(_toml_escape "$pkg_path")"
                [[ -n "$version" ]] && printf '%s.version = "%s"\n' "$install_id" "$(_toml_escape "$version")"
                [[ -n "$pkg_group" ]] && printf '%s.pkg-group = "%s"\n' "$install_id" "$(_toml_escape "$pkg_group")"
                [[ -n "$priority" ]] && printf '%s.priority = %s\n' "$install_id" "$priority"
                ;;
        esac

        # Auto-add systems constraint for flox-cuda packages (Linux-only)
        if [[ "$pkg_path" == flox-cuda/* ]]; then
            printf '%s.systems = ["aarch64-linux", "x86_64-linux"]\n' "$install_id"
        fi
    done < "$deduped"

    printf '\n'
}

_emit_vars_section() {
    local ir_file="$1"

    local vars
    vars=$({ grep "^VAR${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | sort -t "$IR_DELIM" -k2,2 -u)

    if [[ -z "$vars" ]]; then
        printf '[vars]\n\n'
        return 0
    fi

    printf '[vars]\n'

    while IFS="$IR_DELIM" read -r _ name value line_num; do
        value=$(_ir_decode "$value")
        # Check if value contains newlines (shouldn't in [vars], but be safe)
        if [[ "$value" == *$'\n'* ]]; then
            # Use TOML multi-line literal string (no escaping needed inside ''')
            printf "%s = '''\n%s\n'''\n" "$name" "$value"
        else
            printf '%s = "%s"\n' "$name" "$(_toml_escape "$value")"
        fi
    done <<< "$vars"

    printf '\n'
}

_emit_hook_section() {
    local ir_file="$1"

    local hooks
    hooks=$({ grep "^HOOK${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | sort -t "$IR_DELIM" -k2,2n)

    if [[ -z "$hooks" ]]; then
        printf '[hook]\n\n'
        return 0
    fi

    printf '[hook]\n'
    printf "on-activate = '''\n"

    # Emit structured hook content
    local has_env_exports=0

    # First pass: env exports (order 0xx)
    while IFS="$IR_DELIM" read -r _ order bash_line line_num; do
        bash_line=$(_ir_decode "$bash_line")
        if [[ $((10#$order)) -lt 100 ]]; then
            printf '%s\n' "$bash_line"
            has_env_exports=1
        fi
    done <<< "$hooks"

    [[ "$has_env_exports" -eq 1 ]] && printf '\n'

    # Second pass: setup commands and pip/npm comments (order 1xx+)
    while IFS="$IR_DELIM" read -r _ order bash_line line_num; do
        bash_line=$(_ir_decode "$bash_line")
        if [[ $((10#$order)) -ge 100 ]]; then
            printf '%s\n' "$bash_line"
        fi
    done <<< "$hooks"

    # Add standard return-to-project, or the mapped Docker WORKDIR when present.
    if printf '%s' "$hooks" | grep -q 'DOCK2FLOX_ACTIVATE_DIR'; then
        printf '\ncd "${DOCK2FLOX_ACTIVATE_DIR:-$FLOX_ENV_PROJECT}"\n'
    else
        printf '\ncd "$FLOX_ENV_PROJECT"\n'
    fi
    printf "'''\n\n"
}

_emit_services_section() {
    local ir_file="$1"

    # Regular services (command only) — exclude SERVICE_COMPOSE records
    local services
    services=$({ grep "^SERVICE${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | { grep -v "^SERVICE_COMPOSE${IR_DELIM}" 2>/dev/null || true; })

    # Compose-wrapped services (is-daemon + shutdown)
    local compose_services
    compose_services=$({ grep "^SERVICE_COMPOSE${IR_DELIM}" "$ir_file" 2>/dev/null || true; })

    if [[ -z "$services" && -z "$compose_services" ]]; then
        printf '[services]\n\n'
        return 0
    fi

    printf '[services]\n'

    if [[ -n "$services" ]]; then
        while IFS="$IR_DELIM" read -r _ name command line_num; do
            command=$(_ir_decode "$command")
            printf "%s.command = '''\n%s\n'''\n" "$name" "$command"
        done <<< "$services"
    fi

    if [[ -n "$compose_services" ]]; then
        printf '# Compose services managed by Flox — start with flox activate -s\n'
        printf '# Remove docker compose rm -f from shutdown.command to preserve containers between sessions\n'
        while IFS="$IR_DELIM" read -r _ name startup shutdown line_num; do
            startup=$(_ir_decode "$startup")
            shutdown=$(_ir_decode "$shutdown")
            printf '%s.command = "%s"\n' "$name" "$(_toml_escape "$startup")"
            printf '%s.is-daemon = true\n' "$name"
            printf '%s.shutdown.command = "%s"\n' "$name" "$(_toml_escape "$shutdown")"
        done <<< "$compose_services"
    fi

    printf '\n'
}

_emit_options_section() {
    cat <<'EOF'
[options]
systems = [
  "aarch64-darwin",
  "aarch64-linux",
  "x86_64-darwin",
  "x86_64-linux",
]
EOF
}
