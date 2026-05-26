#!/usr/bin/env bash
# dock2flox validator
# Validates package mappings by running flox search against candidates

# Requires: lib/core.sh sourced first

validate_ir() {
    local ir_file="$1"

    # Check that flox is available
    if ! command -v flox &>/dev/null; then
        log_warn "flox not found in PATH — skipping validation"
        return 0
    fi

    # Extract entries that need validation (confidence != EXACT)
    local candidates
    candidates=$(dock2flox_mktemp)
    { grep "^INSTALL${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | grep -v "${IR_DELIM}EXACT${IR_DELIM}" > "$candidates" 2>/dev/null || true

    if [[ ! -s "$candidates" ]]; then
        log_info "All packages mapped with EXACT confidence — nothing to validate"
        return 0
    fi

    local count
    count=$(wc -l < "$candidates")
    log_info "Validating $count package mapping(s)..."

    # Process each candidate
    local validated
    validated=$(dock2flox_mktemp)

    local n_confirmed=0 n_corrected=0 n_unresolved=0

    while IFS="$IR_DELIM" read -r record_type install_id pkg_path version pkg_group confidence line_num notes; do
        local new_confidence="$confidence"
        local new_notes="$notes"
        local new_pkg_path="$pkg_path"
        local was_corrected=0

        # Strategy 1: Search for the heuristic guess directly
        local search_result
        search_result=$(_flox_search_quiet "$pkg_path")

        if [[ -n "$search_result" ]]; then
            if echo "$search_result" | grep -qxF "$pkg_path"; then
                # Exact match — heuristic was correct
                new_confidence="EXACT"
                new_notes="validated via flox search"
                log_verbose "VALIDATED (exact): $pkg_path"
                n_confirmed=$((n_confirmed + 1))
            else
                # Close match — search confirmed a real package with a different name
                local first_match
                first_match=$(echo "$search_result" | head -1)
                new_confidence="EXACT"
                new_pkg_path="$first_match"
                new_notes="corrected via flox search: $pkg_path -> $first_match"
                was_corrected=1
                log_verbose "CORRECTED: $pkg_path -> $first_match"
                n_corrected=$((n_corrected + 1))
            fi
        else
            # Primary search failed — try alternative strategies
            local alt_result=""
            local resolved=0

            # Strategy 2: lowercase
            alt_result=$(_flox_search_quiet "$(echo "$pkg_path" | tr '[:upper:]' '[:lower:]')")
            if [[ -n "$alt_result" ]]; then
                local first_match
                first_match=$(echo "$alt_result" | head -1)
                new_confidence="EXACT"
                new_pkg_path="$first_match"
                new_notes="corrected via flox search (lowercase): $pkg_path -> $first_match"
                was_corrected=1
                resolved=1
                log_verbose "CORRECTED (lowercase): $pkg_path -> $first_match"
                n_corrected=$((n_corrected + 1))
            fi

            # Strategy 3: add lib prefix back
            if [[ "$resolved" -eq 0 && "$pkg_path" != lib* ]]; then
                alt_result=$(_flox_search_quiet "lib${pkg_path}")
                if [[ -n "$alt_result" ]]; then
                    local first_match
                    first_match=$(echo "$alt_result" | head -1)
                    new_confidence="EXACT"
                    new_pkg_path="$first_match"
                    new_notes="corrected via flox search (lib prefix): $pkg_path -> $first_match"
                    was_corrected=1
                    resolved=1
                    log_verbose "CORRECTED (lib prefix): $pkg_path -> $first_match"
                    n_corrected=$((n_corrected + 1))
                fi
            fi

            # Strategy 4: strip trailing version numbers
            if [[ "$resolved" -eq 0 ]]; then
                local stripped
                stripped=$(echo "$pkg_path" | sed -E 's/[0-9]+$//')
                if [[ "$stripped" != "$pkg_path" ]]; then
                    alt_result=$(_flox_search_quiet "$stripped")
                    if [[ -n "$alt_result" ]]; then
                        local first_match
                        first_match=$(echo "$alt_result" | head -1)
                        new_confidence="EXACT"
                        new_pkg_path="$first_match"
                        new_notes="corrected via flox search (stripped version): $pkg_path -> $first_match"
                        was_corrected=1
                        resolved=1
                        log_verbose "CORRECTED (stripped version): $pkg_path -> $first_match"
                        n_corrected=$((n_corrected + 1))
                    fi
                fi
            fi

            # Strategy 5: extract original distro name from notes and try transforms
            if [[ "$resolved" -eq 0 && "$notes" == *"heuristic:"* ]]; then
                local original=""
                # Notes format: "heuristic: stripped -dev/lib prefix from libarpack2-dev"
                original=$(echo "$notes" | sed -E 's/.*from ([^ ]+)$/\1/')
                if [[ -n "$original" && "$original" != "$notes" ]]; then
                    # Try: strip -dev only (keep lib)
                    local try1="${original%-dev}"
                    if [[ "$try1" != "$original" && "$try1" != "$pkg_path" ]]; then
                        alt_result=$(_flox_search_quiet "$try1")
                        if [[ -n "$alt_result" ]]; then
                            local first_match
                            first_match=$(echo "$alt_result" | head -1)
                            new_confidence="EXACT"
                            new_pkg_path="$first_match"
                            new_notes="corrected via flox search (original name): $original -> $first_match"
                            was_corrected=1
                            resolved=1
                            log_verbose "CORRECTED (original): $original -> $first_match"
                            n_corrected=$((n_corrected + 1))
                        fi
                    fi

                    # Try: strip -dev, strip lib, strip trailing digits
                    if [[ "$resolved" -eq 0 ]]; then
                        local try2="${try1#lib}"
                        try2=$(echo "$try2" | sed -E 's/[0-9]+$//')
                        if [[ -n "$try2" && "$try2" != "$pkg_path" && "$try2" != "$try1" ]]; then
                            alt_result=$(_flox_search_quiet "$try2")
                            if [[ -n "$alt_result" ]]; then
                                local first_match
                                first_match=$(echo "$alt_result" | head -1)
                                new_confidence="EXACT"
                                new_pkg_path="$first_match"
                                new_notes="corrected via flox search (derived from $original): $first_match"
                                was_corrected=1
                                resolved=1
                                log_verbose "CORRECTED (derived): $original -> $first_match"
                                n_corrected=$((n_corrected + 1))
                            fi
                        fi
                    fi
                fi
            fi

            if [[ "$resolved" -eq 0 ]]; then
                new_notes="flox search found no match for: $pkg_path"
                log_verbose "NOT FOUND: $pkg_path"
                n_unresolved=$((n_unresolved + 1))
            fi
        fi

        # Write updated record back
        printf 'INSTALL%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$IR_DELIM" "$install_id" "$IR_DELIM" "$new_pkg_path" "$IR_DELIM" "$version" \
            "$IR_DELIM" "$pkg_group" "$IR_DELIM" "$new_confidence" "$IR_DELIM" "$line_num" \
            "$IR_DELIM" "$(_ir_encode "$new_notes")" >> "$validated"

    done < "$candidates"

    # Replace non-EXACT INSTALL records in the IR file with validated versions
    local updated_ir
    updated_ir=$(dock2flox_mktemp)

    # Keep all non-INSTALL records and EXACT INSTALL records
    { grep -v "^INSTALL${IR_DELIM}" "$ir_file" 2>/dev/null || true; } >> "$updated_ir"
    { grep "^INSTALL${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | { grep "${IR_DELIM}EXACT${IR_DELIM}" 2>/dev/null || true; } >> "$updated_ir"

    # Add validated records
    cat "$validated" >> "$updated_ir"

    # Replace original IR
    cp "$updated_ir" "$ir_file"

    # Summary
    local parts=""
    [[ "$n_confirmed" -gt 0 ]] && parts="${n_confirmed} confirmed"
    [[ "$n_corrected" -gt 0 ]] && parts="${parts:+$parts, }${n_corrected} corrected"
    [[ "$n_unresolved" -gt 0 ]] && parts="${parts:+$parts, }${n_unresolved} unresolved"
    log_info "Validation complete: ${parts:-no changes}"
}

_flox_search_quiet() {
    local query="$1"
    [[ -z "$query" ]] && return 0

    # Run flox search with timeout, capture package names only
    local result
    result=$(timeout 10 flox search "$query" 2>/dev/null | head -5 | awk '{print $1}') || true
    printf '%s' "$result"
}
