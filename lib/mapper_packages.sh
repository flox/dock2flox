#!/usr/bin/env bash
# dock2flox package mapper
# Translates distro package names (apt/apk/yum) to nixpkgs pkg-paths
# Uses a 3-layer resolution strategy: static map -> heuristics -> UNMAPPED

# Requires: lib/core.sh sourced first

# --- Main entry point ---

map_package() {
    local pkg_manager="$1"  # apt, apk, yum
    local pkg_name="$2"
    local ir_file="$3"
    local line_num="$4"

    local nixpkgs_path=""
    local confidence="UNMAPPED"
    local notes=""
    local install_id=""

    # Layer 1: Static table lookup
    nixpkgs_path=$(_lookup_static_map "$pkg_manager" "$pkg_name")
    if [[ -n "$nixpkgs_path" ]]; then
        confidence="EXACT"
        install_id=$(_make_install_id "$nixpkgs_path")
        # Check for notes in the map
        notes=$(_lookup_static_notes "$pkg_manager" "$pkg_name")
        ir_install "$ir_file" "$install_id" "$nixpkgs_path" "" "" "$confidence" "$line_num" "$notes"
        log_verbose "EXACT: $pkg_name -> $nixpkgs_path"
        return 0
    fi

    # Layer 2: Heuristic transforms
    nixpkgs_path=$(_heuristic_transform "$pkg_manager" "$pkg_name")
    if [[ -n "$nixpkgs_path" ]]; then
        confidence="HIGH"
        install_id=$(_make_install_id "$nixpkgs_path")
        notes="heuristic: $pkg_name"
        ir_install "$ir_file" "$install_id" "$nixpkgs_path" "" "" "$confidence" "$line_num" "$notes"
        log_verbose "HIGH: $pkg_name -> $nixpkgs_path (heuristic)"
        return 0
    fi

    # Layer 3: Unmapped fallback
    confidence="UNMAPPED"
    install_id=$(_sanitize_id "$pkg_name")
    nixpkgs_path="$pkg_name"
    notes="UNMAPPED from $pkg_manager"
    ir_install "$ir_file" "$install_id" "$nixpkgs_path" "" "" "$confidence" "$line_num" "$notes"
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
    result=$(awk -F'\t' -v pkg="$pkg_name" '$1 == pkg {print $2; exit}' "$map_file")
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
    result=$(awk -F'\t' -v pkg="$pkg_name" '$1 == pkg && NF >= 3 {print $3; exit}' "$map_file")
    printf '%s' "$result"
}

# --- Layer 2: Heuristic transforms ---

_heuristic_transform() {
    local pkg_manager="$1"
    local pkg_name="$2"

    local candidate=""

    # Heuristic 1: strip -dev suffix (common for C libraries)
    if [[ "$pkg_name" == *-dev ]]; then
        candidate="${pkg_name%-dev}"
        # Also strip lib prefix if present
        if [[ "$candidate" == lib* ]]; then
            candidate="${candidate#lib}"
        fi
        # Check if the stripped name exists in the map
        local mapped
        mapped=$(_lookup_static_map "$pkg_manager" "$candidate")
        if [[ -n "$mapped" ]]; then
            printf '%s' "$mapped"
            return 0
        fi
        # Return the candidate as-is (will be validated later if --validate)
        printf '%s' "$candidate"
        return 0
    fi

    # Heuristic 2: strip lib prefix
    if [[ "$pkg_name" == lib* && "$pkg_name" != "libtool" ]]; then
        candidate="${pkg_name#lib}"
        # Remove trailing version numbers (e.g., libxml2 -> xml2 -> libxml2 in nix)
        # Actually, many nix packages keep the lib prefix, so try both
        local mapped
        mapped=$(_lookup_static_map "$pkg_manager" "$candidate")
        if [[ -n "$mapped" ]]; then
            printf '%s' "$mapped"
            return 0
        fi
        # Try with lib prefix in nixpkgs (many nix pkgs keep it)
        printf '%s' "$pkg_name"
        return 0
    fi

    # Heuristic 3: version-suffixed packages (python3.11 -> python311)
    if [[ "$pkg_name" =~ ^([a-z]+)([0-9]+)\.([0-9]+)$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local major="${BASH_REMATCH[2]}"
        local minor="${BASH_REMATCH[3]}"
        printf '%s%s%s' "$base" "$major" "$minor"
        return 0
    fi

    # Heuristic 4: python3-* packages -> python3XXPackages.*
    if [[ "$pkg_name" == python3-* ]]; then
        local pyname="${pkg_name#python3-}"
        printf 'python313Packages.%s' "$pyname"
        return 0
    fi
    if [[ "$pkg_name" == py3-* ]]; then
        local pyname="${pkg_name#py3-}"
        printf 'python313Packages.%s' "$pyname"
        return 0
    fi

    # Heuristic 5: strip common suffixes (-bin, -common, -utils)
    if [[ "$pkg_name" == *-bin || "$pkg_name" == *-common || "$pkg_name" == *-utils ]]; then
        candidate="${pkg_name%-bin}"
        candidate="${candidate%-common}"
        candidate="${candidate%-utils}"
        printf '%s' "$candidate"
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
