#!/usr/bin/env bash
# dock2flox package mapper
# Translates distro package names (apt/apk/yum) to nixpkgs pkg-paths
# Uses a 3-layer resolution strategy: static map -> reviewed heuristics -> UNMAPPED

# Requires: lib/core.sh sourced first

# --- Main entry point ---

map_package() {
    local pkg_manager="$1"  # apt, apk, yum
    local pkg_name="$2"
    local ir_file="$3"
    local line_num="$4"
    local version="${5:-}"

    local nixpkgs_path=""
    local confidence="UNMAPPED"
    local notes=""
    local install_id=""

    # Layer 1: Static table lookup
    nixpkgs_path=$(_lookup_static_map "$pkg_manager" "$pkg_name")
    if [[ -n "$nixpkgs_path" ]]; then
        # Handle _skip_ sentinel (container-specific packages like gosu)
        if [[ "$nixpkgs_path" == "_skip_" ]]; then
            log_verbose "SKIP: $pkg_name (container-specific, not needed in Flox)"
            return 0
        fi
        confidence="EXACT"
        install_id=$(_make_install_id "$nixpkgs_path")
        # Check for notes in the map
        notes=$(_lookup_static_notes "$pkg_manager" "$pkg_name")
        ir_install "$ir_file" "$install_id" "$nixpkgs_path" "$version" "" "$confidence" "$line_num" "$notes"
        log_verbose "EXACT: $pkg_name -> $nixpkgs_path"
        return 0
    fi

    # Layer 2: Heuristic transforms. Heuristics are intentionally reviewable:
    # they reduce bounded map coverage, but they must not pretend an uncommon
    # distro package is definitely available in the Flox catalog.
    local heuristic_record
    heuristic_record=$(_heuristic_transform "$pkg_manager" "$pkg_name")
    if [[ -n "$heuristic_record" ]]; then
        IFS=$'\t' read -r nixpkgs_path confidence notes <<< "$heuristic_record"
        install_id=$(_make_install_id "$nixpkgs_path")
        ir_install "$ir_file" "$install_id" "$nixpkgs_path" "$version" "" "$confidence" "$line_num" "$notes"
        if [[ "$confidence" != "HIGH" ]]; then
            ir_review "$ir_file" "package-map" "$pkg_name from $pkg_manager mapped heuristically to $nixpkgs_path; verify with flox search before relying on it." "$line_num"
        fi
        log_verbose "$confidence: $pkg_name -> $nixpkgs_path (heuristic)"
        return 0
    fi

    # Layer 3: Unmapped fallback. Leave the candidate commented in [install] and
    # emit a top-level review note rather than silently dropping package intent.
    confidence="UNMAPPED"
    install_id=$(_sanitize_id "$pkg_name")
    nixpkgs_path="$pkg_name"
    notes="UNMAPPED from $pkg_manager"
    ir_install "$ir_file" "$install_id" "$nixpkgs_path" "$version" "" "$confidence" "$line_num" "$notes"
    ir_review "$ir_file" "package-map" "$pkg_name from $pkg_manager has no static Flox mapping; search the Flox catalog or add a data/*.map entry." "$line_num"
    log_verbose "UNMAPPED: $pkg_name (no mapping found)"
    return 0
}

# --- Layer 1: Static map lookup ---

_lookup_static_map() {
    local pkg_manager="$1"
    local pkg_name="$2"

    local map_file
    case "$pkg_manager" in
        apt|deb) map_file="$DOCK2FLOX_DATA/apt_to_nixpkgs.map" ;;
        apk)     map_file="$DOCK2FLOX_DATA/apk_to_nixpkgs.map" ;;
        yum|dnf) map_file="$DOCK2FLOX_DATA/apt_to_nixpkgs.map" ;; # yum close enough to apt names
        *)       map_file="$DOCK2FLOX_DATA/apt_to_nixpkgs.map" ;;
    esac

    [[ ! -f "$map_file" ]] && return 0

    # Search for exact match (field 1, tab-separated)
    local result
    result=$(awk -F'\t' -v pkg="$pkg_name" '$1 == pkg && !found {print $2; found=1}' "$map_file")
    printf '%s' "$result"
}

_lookup_static_notes() {
    local pkg_manager="$1"
    local pkg_name="$2"

    local map_file
    case "$pkg_manager" in
        apt|deb) map_file="$DOCK2FLOX_DATA/apt_to_nixpkgs.map" ;;
        apk)     map_file="$DOCK2FLOX_DATA/apk_to_nixpkgs.map" ;;
        *)       map_file="$DOCK2FLOX_DATA/apt_to_nixpkgs.map" ;;
    esac

    [[ ! -f "$map_file" ]] && return 0

    local result
    result=$(awk -F'\t' -v pkg="$pkg_name" '$1 == pkg && NF >= 3 && !found {print $3; found=1}' "$map_file")
    printf '%s' "$result"
}

# --- Layer 2: Heuristic transforms ---

_heuristic_transform() {
    local pkg_manager="$1"
    local pkg_name="$2"

    local candidate=""

    # Heuristic 1: strip -dev suffix (common for C libraries). If the stripped
    # name lands in a static map, confidence is HIGH; otherwise leave it LOW.
    if [[ "$pkg_name" == *-dev ]]; then
        candidate="${pkg_name%-dev}"
        if [[ "$candidate" == lib* ]]; then
            candidate="${candidate#lib}"
        fi
        local mapped
        mapped=$(_lookup_static_map "$pkg_manager" "$candidate")
        if [[ -n "$mapped" ]]; then
            printf '%s\tHIGH\theuristic: %s -> mapped static package %s' "$mapped" "$pkg_name" "$candidate"
            return 0
        fi
        printf '%s\tLOW\theuristic: stripped -dev/lib prefix from %s' "$candidate" "$pkg_name"
        return 0
    fi

    # Heuristic 2: strip lib prefix. This is frequently useful but not certain.
    if [[ "$pkg_name" == lib* && "$pkg_name" != "libtool" ]]; then
        candidate="${pkg_name#lib}"
        local mapped
        mapped=$(_lookup_static_map "$pkg_manager" "$candidate")
        if [[ -n "$mapped" ]]; then
            printf '%s\tHIGH\theuristic: %s -> mapped static package %s' "$mapped" "$pkg_name" "$candidate"
            return 0
        fi
        printf '%s\tLOW\theuristic: retained original library package name %s' "$pkg_name" "$pkg_name"
        return 0
    fi

    # Heuristic 3: version-suffixed packages (python3.11 -> python311).
    if [[ "$pkg_name" =~ ^([a-z]+)([0-9]+)\.([0-9]+)$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        printf '%s%s%s\tLOW\theuristic: converted versioned package name %s' "$base" "$major" "$minor" "$pkg_name"
        return 0
    fi

    # Heuristic 4: python3-* / py3-* packages -> python313Packages.*.
    if [[ "$pkg_name" == python3-* ]]; then
        local pyname="${pkg_name#python3-}"
        printf 'python313Packages.%s\tLOW\theuristic: converted distro Python package %s' "$pyname" "$pkg_name"
        return 0
    fi
    if [[ "$pkg_name" == py3-* ]]; then
        local pyname="${pkg_name#py3-}"
        printf 'python313Packages.%s\tLOW\theuristic: converted Alpine Python package %s' "$pyname" "$pkg_name"
        return 0
    fi

    # Heuristic 5: versioned Alpine PHP packages (php82-curl, php83-gd, php84, etc.) → php
    if [[ "$pkg_name" =~ ^php[0-9]+ ]]; then
        printf 'php\tEXACT\theuristic: Alpine versioned PHP package %s (extensions built into php)' "$pkg_name"
        return 0
    fi

    # Heuristic 6: strip common suffixes (-bin, -common, -utils).
    if [[ "$pkg_name" == *-bin || "$pkg_name" == *-common || "$pkg_name" == *-utils ]]; then
        candidate="${pkg_name%-bin}"
        candidate="${candidate%-common}"
        candidate="${candidate%-utils}"
        printf '%s\tLOW\theuristic: stripped common suffix from %s' "$candidate" "$pkg_name"
        return 0
    fi

    # No heuristic matched
    return 0
}

# --- Utility functions ---

_make_install_id() {
    local pkg_path="$1"
    # Convert pkg-path to a valid install ID
    # e.g., "python313Packages.pip" -> "pip"
    # e.g., "gcc" -> "gcc"
    if [[ "$pkg_path" == *.* ]]; then
        # Take the last component
        printf '%s' "${pkg_path##*.}"
    else
        printf '%s' "$pkg_path"
    fi
}

_sanitize_id() {
    local name="$1"
    # Replace invalid chars with underscores, strip leading digits
    name="${name//[^a-zA-Z0-9_-]/_}"
    name="${name#[0-9]}"
    printf '%s' "$name"
}
