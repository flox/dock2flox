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

    while IFS="$IR_DELIM" read -r record_type install_id pkg_path version pkg_group confidence line_num notes; do
        local new_confidence="$confidence"
        local new_notes="$notes"
        local new_pkg_path="$pkg_path"

        # Run flox search
        local search_result
        search_result=$(_flox_search_quiet "$pkg_path")

        if [[ -n "$search_result" ]]; then
            # Check for exact match (use grep -F for fixed string, not regex)
            if echo "$search_result" | grep -qxF "$pkg_path"; then
                new_confidence="EXACT"
                new_notes="validated via flox search"
                log_verbose "VALIDATED (exact): $pkg_path"
            else
                # Close match found
                local first_match
                first_match=$(echo "$search_result" | head -1)
                new_confidence="HIGH"
                new_pkg_path="$first_match"
                new_notes="flox search suggests: $first_match (original: $pkg_path)"
                log_verbose "VALIDATED (close): $pkg_path -> $first_match"
            fi
        else
            # Try alternative search strategies
            local alt_result=""

            # Strategy 1: lowercase
            alt_result=$(_flox_search_quiet "$(echo "$pkg_path" | tr '[:upper:]' '[:lower:]')")
            if [[ -n "$alt_result" ]]; then
                local first_match
                first_match=$(echo "$alt_result" | head -1)
                new_confidence="HIGH"
                new_pkg_path="$first_match"
                new_notes="flox search (lowercase) suggests: $first_match"
                log_verbose "VALIDATED (alt): $pkg_path -> $first_match"
            else
                # Strategy 2: strip version numbers
                local stripped
                stripped=$(echo "$pkg_path" | sed -E 's/[0-9]+$//')
                if [[ "$stripped" != "$pkg_path" ]]; then
                    alt_result=$(_flox_search_quiet "$stripped")
                    if [[ -n "$alt_result" ]]; then
                        local first_match
                        first_match=$(echo "$alt_result" | head -1)
                        new_confidence="LOW"
                        new_pkg_path="$first_match"
                        new_notes="flox search (stripped version) suggests: $first_match (original: $pkg_path)"
                        log_verbose "VALIDATED (stripped): $pkg_path -> $first_match"
                    fi
                fi
            fi

            if [[ "$new_confidence" == "$confidence" ]]; then
                new_notes="flox search found no match for: $pkg_path"
                log_verbose "NOT FOUND: $pkg_path"
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

    local validated_count
    validated_count=$(grep -c "${IR_DELIM}EXACT${IR_DELIM}" "$validated" 2>/dev/null || echo 0)
    log_info "Validation complete: $validated_count/$count confirmed"
}

_flox_search_quiet() {
    local query="$1"
    [[ -z "$query" ]] && return 0

    # Run flox search with timeout, capture package names only
    local result
    result=$(timeout 10 flox search "$query" 2>/dev/null | head -5 | awk '{print $1}') || true
    printf '%s' "$result"
}
