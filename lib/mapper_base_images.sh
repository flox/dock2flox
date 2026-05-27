#!/usr/bin/env bash
# dock2flox base image mapper
# Maps FROM image:tag specifications to implied [install] packages

# Requires: lib/core.sh sourced first

map_base_image() {
    local image_spec="$1"
    local ir_file="$2"
    local line_num="$3"

    # Parse image:tag
    local image tag
    if [[ "$image_spec" == *":"* ]]; then
        image="${image_spec%%:*}"
        tag="${image_spec#*:}"
    else
        image="$image_spec"
        tag="latest"
    fi

    # Strip registry prefix if present (e.g., docker.io/library/python -> python)
    image="${image##*/}"

    # Look up in base_images.map
    local map_file="$DOCK2FLOX_DATA/base_images.map"
    if [[ ! -f "$map_file" ]]; then
        log_warn "Base image map not found: $map_file"
        return 0
    fi

    local pkg_path version_regex pkg_group
    local found=0

    while IFS=$'\t' read -r map_image map_pkg_path map_version_regex map_pkg_group; do
        # Skip comments and empty lines
        [[ -z "$map_image" || "$map_image" == "#"* ]] && continue

        if [[ "$image" == "$map_image" ]]; then
            pkg_path="$map_pkg_path"
            version_regex="$map_version_regex"
            pkg_group="$map_pkg_group"
            found=1
            break
        fi
    done < "$map_file"

    if [[ "$found" -eq 0 ]]; then
        log_verbose "No base image mapping for: $image"
        ir_skip "$ir_file" "FROM $image_spec" "unknown base image" "$line_num"
        return 0
    fi

    # Skip OS-only images (marked with _ placeholder)
    if [[ "$pkg_path" == "_" ]]; then
        log_verbose "Base OS image (no packages implied): $image"
        ir_skip "$ir_file" "FROM $image_spec" "base OS image (no packages implied)" "$line_num"
        return 0
    fi

    # Extract version from tag using the regex
    local version=""
    if [[ "$version_regex" != "_" && "$tag" != "latest" ]]; then
        if [[ "$tag" =~ $version_regex ]]; then
            version="${BASH_REMATCH[1]}"
        fi
    fi

    # Construct the install ID and pkg-path
    local install_id
    install_id=$(_base_image_install_id "$pkg_path" "$version")
    local resolved_pkg_path
    resolved_pkg_path=$(_base_image_pkg_path "$pkg_path" "$version" "$image")

    # Determine pkg-group (only set if not "runtime" default)
    local group_value=""
    if [[ "$pkg_group" != "_" && "$pkg_group" != "runtime" ]]; then
        group_value="$pkg_group"
    fi

    # Format version for Flox (semver-ish)
    local flox_version=""
    if [[ -n "$version" ]]; then
        flox_version="$version"
    fi

    ir_install "$ir_file" "$install_id" "$resolved_pkg_path" "$flox_version" "$group_value" "EXACT" "$line_num" "from base image $image_spec"

    log_verbose "Base image: $image_spec -> $resolved_pkg_path (version: ${flox_version:-latest})"
}

_base_image_install_id() {
    local pkg_path="$1"
    local version="$2"

    # Simple: use the base name
    # python3 -> python3, nodejs -> nodejs, etc.
    if [[ "$pkg_path" == *.* ]]; then
        printf '%s' "${pkg_path##*.}"
    else
        printf '%s' "$pkg_path"
    fi
}

_base_image_pkg_path() {
    local pkg_path="$1"
    local version="$2"
    local image="$3"

    # Always return the base package name — let the version constraint
    # handle version matching. Flox's resolver finds historical versions
    # across the catalog (e.g., python3 with version="3.12" resolves correctly).
    # Do NOT mangle names like python313 or nodejs_20 — these create redundant
    # version conflicts when combined with a version constraint.
    # All images: return the base package name as-is
    printf '%s' "$pkg_path"
}
