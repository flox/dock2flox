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
    local -A env_table=()       # Dockerfile ENV name -> value visible to later RUN
    local stage_index=0         # current FROM stage index
    local stage_name=""         # current FROM stage AS name
    local final_stage_start=0   # line number where final stage begins
    local line_num=0
    local pkg_manager=""        # detected package manager (apt/apk/yum)
    local current_platform=""   # Docker --platform for final stage, e.g. linux/arm64
    local current_arch="x86_64" # uname -m model for RUN interpretation
    local current_shell_kind="sh" # Docker default Linux shell semantics
    local current_shell_explicit=0 # 1 if user explicitly set SHELL instruction
    local current_shell_desc="/bin/sh -c"

    # Best-effort OCI/runtime metadata from the final stage. Flox environments
    # are not OCI images, so these records preserve intent and translate the
    # parts that have a useful activation/service equivalent.
    local oci_workdir=""
    local oci_user=""
    local oci_entrypoint=""
    local oci_cmd=""
    local oci_exposed_ports=""
    local oci_volumes=""
    local oci_healthcheck=""
    local oci_stopsignal=""
    local oci_shell=""

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

    # Second pass: build stage name maps for multi-stage inheritance
    local -A stage_name_to_index=()
    local -A stage_from_target=()
    local pass2_stage=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*FROM[[:space:]] ]] || continue
        pass2_stage=$((pass2_stage + 1))

        # Extract image spec (before AS clause)
        local pass2_image
        pass2_image=$(printf '%s\n' "$line" | sed -E 's/^FROM[[:space:]]+(--platform=([^[:space:]]+)[[:space:]]+)?//I' | awk '{print $1}')
        pass2_image=$(_substitute_args "$pass2_image")
        stage_from_target[$pass2_stage]="$pass2_image"

        # Extract AS name
        if [[ "$line" =~ [Aa][Ss][[:space:]]+([a-zA-Z0-9_-]+) ]]; then
            stage_name_to_index["${BASH_REMATCH[1]}"]=$pass2_stage
        fi
    done < "$processed"

    # Resolve runtime chain: walk from final stage back through FROM references
    local -A runtime_chain=()
    _resolve_runtime_chain "$total_stages" stage_name_to_index stage_from_target runtime_chain

    # Third pass: parse instructions
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
                # Emit from all stages in the runtime chain (ENV inherits via FROM)
                if [[ -n "${runtime_chain[$current_stage]:-}" ]]; then
                    _parse_env "$line" "$ir_file" "$line_num"
                fi
                ;;
            RUN)
                # Emit from all stages in the runtime chain
                if [[ -n "${runtime_chain[$current_stage]:-}" ]]; then
                    _parse_run "$line" "$ir_file" "$line_num"
                fi
                ;;
            EXPOSE)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_expose "$line" "$ir_file" "$line_num"
                fi
                ;;
            WORKDIR)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_workdir "$line" "$ir_file" "$line_num"
                fi
                ;;
            USER)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_user "$line" "$ir_file" "$line_num"
                fi
                ;;
            CMD)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_cmd "$line" "$ir_file" "$line_num"
                fi
                ;;
            ENTRYPOINT)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_entrypoint "$line" "$ir_file" "$line_num"
                fi
                ;;
            COPY|ADD)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_copy_add "$instruction" "$line" "$ir_file" "$line_num"
                fi
                ;;
            HEALTHCHECK)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_healthcheck "$line" "$ir_file" "$line_num"
                fi
                ;;
            STOPSIGNAL)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_stopsignal "$line" "$ir_file" "$line_num"
                fi
                ;;
            SHELL)
                # Emit from all stages in the runtime chain (shell state affects RUN)
                if [[ -n "${runtime_chain[$current_stage]:-}" ]]; then
                    _parse_shell "$line" "$ir_file" "$line_num"
                fi
                ;;
            LABEL)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_label "$line" "$ir_file" "$line_num"
                fi
                ;;
            VOLUME)
                if [[ "$current_stage" -eq "$total_stages" ]]; then
                    _parse_volume "$line" "$ir_file" "$line_num"
                fi
                ;;
        esac
    done < "$processed"

    _emit_oci_final_records "$ir_file" "$line_num"

    log_info "Parsed $line_num lines, $total_stages stage(s)"
}

# --- Internal helpers ---

_dockerfile_collapse_continuations() {
    local file="$1"
    # Join lines ending with \ with the next line. Also normalize the common
    # Dockerfile heredoc form:
    #   RUN <<EOF
    #     apt-get install -y curl
    #   EOF
    # into one logical RUN record with record-separator bytes standing in for
    # newlines. _parse_run restores those newlines before handing the body to
    # Bash. This keeps the main parser line-oriented while letting Bash, not a
    # text splitter, interpret the heredoc script body.
    local logical="" line
    local in_run_heredoc=0 marker="" strip_tabs=0 heredoc_body=""
    local nl_marker=$'\x1e'

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_run_heredoc" -eq 1 ]]; then
            local marker_candidate="$line"
            if [[ "$strip_tabs" -eq 1 ]]; then
                while [[ "$marker_candidate" == $'\t'* ]]; do
                    marker_candidate="${marker_candidate#$'\t'}"
                done
            fi

            if [[ "$marker_candidate" == "$marker" ]]; then
                printf 'RUN %s\n' "${heredoc_body%$nl_marker}"
                in_run_heredoc=0
                marker=""
                strip_tabs=0
                heredoc_body=""
                continue
            fi

            if [[ -n "$heredoc_body" ]]; then
                heredoc_body+="$nl_marker"
            fi
            heredoc_body+="$line"
            continue
        fi

        if [[ -z "$logical" ]]; then
            logical="$line"
        else
            logical+=" $line"
        fi

        if [[ "$logical" == *\\ ]]; then
            logical="${logical%\\}"
            continue
        fi

        local trimmed="$logical"
        trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        if [[ "$trimmed" =~ ^[Rr][Uu][Nn][[:space:]]+\<\<-?[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
            marker="${BASH_REMATCH[1]}"
            if [[ "$trimmed" == *'<<-'* ]]; then
                strip_tabs=1
            else
                strip_tabs=0
            fi
            marker="${marker#\'}"; marker="${marker%\'}"
            marker="${marker#\"}"; marker="${marker%\"}"
            in_run_heredoc=1
            heredoc_body=""
            logical=""
            continue
        fi

        printf '%s\n' "$logical"
        logical=""
    done < "$file"

    if [[ "$in_run_heredoc" -eq 1 ]]; then
        printf 'RUN %s\n' "${heredoc_body%$nl_marker}"
    elif [[ -n "$logical" ]]; then
        printf '%s\n' "$logical"
    fi
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

_substitute_args_and_env() {
    local text="$1"
    text=$(_substitute_args "$text")
    local key val safe_val
    for key in "${!env_table[@]}"; do
        val="${env_table[$key]}"
        safe_val="${val//\\/\\\\}"
        safe_val="${safe_val//&/\\&}"
        text="${text//\$\{$key\}/$safe_val}"
        text="${text//\$$key/$safe_val}"
    done
    printf '%s' "$text"
}

_write_run_env_file() {
    local env_file="$1"
    : > "$env_file"
    local key val
    for key in "${!env_table[@]}"; do
        val="${env_table[$key]}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        printf 'export %s=%q\n' "$key" "$val" >> "$env_file"
    done
}


_resolve_runtime_chain() {
    local stage="$1"
    local -n _names="$2"
    local -n _targets="$3"
    local -n _chain="$4"
    local depth=0 max_depth=20

    while [[ "$stage" -gt 0 && "$depth" -lt "$max_depth" ]]; do
        _chain[$stage]=1
        local from_target="${_targets[$stage]:-}"
        [[ -z "$from_target" ]] && break

        # Check if from_target is a named stage
        local parent="${_names[$from_target]:-}"
        if [[ -n "$parent" ]]; then
            stage="$parent"
        else
            break  # External image — end of chain
        fi
        depth=$((depth + 1))
    done
}

_parse_from() {
    local line="$1" ir_file="$2" line_num="$3" current_stage="$4" total_stages="$5"

    # FROM [--platform=...] image[:tag] [AS name]
    local platform platform_raw image_spec
    platform_raw=$(_extract_from_platform "$line")
    platform=$(_substitute_args "$platform_raw")
    # BuildKit's automatic TARGETPLATFORM may appear without a concrete value in
    # the Dockerfile. Preserve unresolved platform expressions so RUN arch probes
    # fail closed instead of silently defaulting to x86_64.
    if [[ -z "$platform" && "$platform_raw" == *'$'* ]]; then
        platform="$platform_raw"
    fi

    image_spec=$(printf '%s\n' "$line" | sed -E 's/^FROM[[:space:]]+(--platform=([^[:space:]]+)[[:space:]]+)?//I' | awk '{print $1}')
    image_spec=$(_substitute_args "$image_spec")

    # Extract AS name if present
    if [[ "$line" =~ [Aa][Ss][[:space:]]+([a-zA-Z0-9_-]+) ]]; then
        stage_name="${BASH_REMATCH[1]}"
    else
        stage_name=""
    fi

    # Check if this stage is in the runtime chain
    local in_runtime_chain=0
    [[ -n "${runtime_chain[$current_stage]:-}" ]] && in_runtime_chain=1

    # Check if FROM target is a named stage (not an external image)
    local from_is_stage=0
    [[ -n "${stage_name_to_index[$image_spec]:-}" ]] && from_is_stage=1

    if [[ "$in_runtime_chain" -eq 1 && "$from_is_stage" -eq 0 ]]; then
        # Runtime chain stage with external base image: full setup + map_base_image
        pkg_manager=$(_infer_pkg_manager_from_image "$image_spec")
        current_platform="${platform:-${TARGETPLATFORM:-}}"
        current_arch=$(_platform_to_uname_machine "${current_platform:-}")
        if [[ -z "$current_arch" ]]; then
            if [[ -n "$current_platform" ]]; then
                ir_review "$ir_file" "run-platform" "FROM platform '$current_platform' is not concrete or not modelled; RUN architecture probes are treated as uncertain rather than defaulting to x86_64." "$line_num"
                current_arch="unknown"
            else
                current_arch="x86_64"
            fi
        fi
        current_shell_kind="sh"
        current_shell_explicit=0
        current_shell_desc="/bin/sh -c"
        if [[ "$current_stage" -eq "$total_stages" ]]; then
            # Only the final stage emits base image install + platform metadata
            map_base_image "$image_spec" "$ir_file" "$line_num"
            if [[ -n "$current_platform" ]]; then
                ir_var "$ir_file" "DOCK2FLOX_CONTAINER_PLATFORM" "$current_platform" "$line_num"
            fi
            if [[ -n "$current_platform" && "$current_arch" != "unknown" ]]; then
                ir_hook "$ir_file" "$((2100 + line_num))" "# RUN interpreter models uname -m as $current_arch for platform $current_platform." "$line_num"
            elif [[ -n "$current_platform" ]]; then
                ir_hook "$ir_file" "$((2100 + line_num))" "# RUN interpreter cannot model uname -m for non-concrete platform $current_platform; architecture-specific extraction requires review." "$line_num"
            fi
        fi
    elif [[ "$in_runtime_chain" -eq 1 && "$from_is_stage" -eq 1 ]]; then
        # Runtime chain stage inheriting from another stage: inherit pkg_manager/arch/shell
        # (already set by the ancestor stage's processing — don't reset)
        :
    else
        ir_skip "$ir_file" "FROM $image_spec (stage $current_stage)" "intermediate build stage" "$line_num"
    fi
}

_extract_from_platform() {
    local line="$1"
    if [[ "$line" =~ [Ff][Rr][Oo][Mm][[:space:]]+--platform=([^[:space:]]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

_platform_to_uname_machine() {
    local platform="$1" arch=""
    platform="${platform,,}"
    case "$platform" in
        */amd64|amd64|x86_64) arch="x86_64" ;;
        */arm64|*/aarch64|arm64|aarch64) arch="aarch64" ;;
        */arm/v7|arm/v7|armhf) arch="armv7l" ;;
        */arm/v6|arm/v6) arch="armv6l" ;;
        */386|386|i386) arch="i686" ;;
        */ppc64le|ppc64le) arch="ppc64le" ;;
        */s390x|s390x) arch="s390x" ;;
        "") arch="x86_64" ;;
        *'$'*|*'{'*|*'}'*) arch="" ;;
        *) arch="" ;;
    esac
    printf '%s' "$arch"
}

_infer_pkg_manager_from_image() {
    local image_spec="$1"
    local image tag

    if [[ "$image_spec" == *":"* ]]; then
        image="${image_spec%%:*}"
        tag="${image_spec#*:}"
    else
        image="$image_spec"
        tag="latest"
    fi

    image="${image##*/}"
    image="${image,,}"
    tag="${tag,,}"

    if [[ "$image" == *alpine* || "$tag" == *alpine* ]]; then
        printf 'apk'
        return 0
    fi

    case "$image" in
        debian|ubuntu|python|node|golang|ruby|rust|openjdk|eclipse-temurin|amazoncorretto)
            printf 'apt'
            return 0
            ;;
        centos|rockylinux|almalinux|amazonlinux)
            printf 'yum'
            return 0
            ;;
        fedora)
            printf 'dnf'
            return 0
            ;;
    esac

    case "$tag" in
        *bookworm*|*bullseye*|*buster*|*slim*|*jammy*|*focal*|*noble*)
            printf 'apt'
            return 0
            ;;
    esac

    printf 'unknown'
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
    env_body=$(_substitute_args_and_env "$env_body")

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

    # Docker passes ENV values into later RUN instructions. Track them even when
    # the generated Flox manifest represents the value differently.
    if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        env_table["$name"]="$value"
    fi

    # POETRY_HOME=/usr/local is a container-global install prefix. In Flox the
    # environment root is the portable equivalent; emit it as a derived hook var
    # rather than a literal [vars] value.
    if [[ "$name" == "POETRY_HOME" && ( "$value" == "/usr/local" || "$value" == "/usr/local/" ) ]]; then
        ir_hook "$ir_file" "050" 'export POETRY_HOME="$FLOX_ENV"' "$line_num"
        return 0
    fi

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
    run_body="${run_body//$'\x1e'/$'\n'}"
    run_body=$(_substitute_args "$run_body")

    if [[ "${current_arch:-x86_64}" == "unknown" && "$run_body" == *uname* ]]; then
        ir_review "$ir_file" "run-platform" "RUN line $line_num contains architecture probes but FROM --platform is not concrete or not modelled; active extraction skipped." "$line_num"
        ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: architecture-dependent shell not analyzed; review manually: $(_single_line_preview "$run_body")" "$line_num"
        return 0
    fi

    # Determine Docker SHELL before classifying the RUN body. The safe-subset
    # gate is deliberately allowlist-oriented: Bash is invoked only after the
    # body avoids unsupported command-introducing syntax. Older denylist checks
    # remain below as defense-in-depth and for more specific review notes.
    local shell_kind="${current_shell_kind:-sh}"

    # Fix A: Reject bash-specific syntax when SHELL is EXPLICITLY set to /bin/sh
    # Default Docker shell is also "sh" but in practice resolves to bash on Debian/Ubuntu,
    # so we only reject when the user explicitly declared SHELL ["/bin/sh", "-c"]
    if [[ "$shell_kind" == "sh" && "$current_shell_explicit" -eq 1 ]] && _run_body_has_bashism "$run_body"; then
        ir_review "$ir_file" "run-shell" "RUN line $line_num uses bash-specific syntax (arrays, [[ ]]) under SHELL [\"/bin/sh\", \"-c\"]; active extraction skipped." "$line_num"
        ir_hook "$ir_file" "200" "# RUN (bash syntax under /bin/sh): $run_body" "$line_num"
        return 0
    fi

    local subset_issue subset_kind subset_detail
    subset_issue=$(_run_body_safe_subset_issue "$run_body" "$shell_kind" || true)
    if [[ -n "$subset_issue" ]]; then
        subset_kind="${subset_issue%%$'	'*}"
        subset_detail="${subset_issue#*$'	'}"
        case "$subset_kind" in
            run-path)
                ir_review "$ir_file" "run-path" "RUN line $line_num contains command dispatch outside dock2flox's safe modeled subset ($subset_detail). The command was not executed on the analyzer host; review manually." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: unsafe/path-addressed command not interpreted by dock2flox; review manually: $(_single_line_preview "$run_body")" "$line_num"
                return 0
                ;;
            run-function)
                ir_review "$ir_file" "run-function" "RUN line $line_num defines a shell function. dock2flox did not execute it because function bodies can hide path-addressed or variable-expanded host commands; review manually." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: shell function not interpreted by dock2flox; review manually: $(_single_line_preview "$run_body")" "$line_num"
                return 0
                ;;
            *)
                ir_review "$ir_file" "run-unsupported" "RUN line $line_num uses shell syntax outside dock2flox's safe interpreted subset ($subset_detail). Active extraction skipped; review manually." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: unsupported shell syntax not interpreted by dock2flox; review manually: $(_single_line_preview "$run_body")" "$line_num"
                return 0
                ;;
        esac
    fi

    local safety_issue safety_kind safety_detail
    safety_issue=$(_run_body_safety_issue "$run_body" || true)
    if [[ -n "$safety_issue" ]]; then
        safety_kind="${safety_issue%%$'\t'*}"
        safety_detail="${safety_issue#*$'\t'}"
        case "$safety_kind" in
            PATH)
                ir_review "$ir_file" "run-path" "RUN line $line_num contains path-addressed command '$safety_detail'. dock2flox did not execute it on the analyzer host; review the command manually." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: path-addressed command not executed by dock2flox; review manually: $(_single_line_preview "$run_body")" "$line_num"
                return 0
                ;;
            VARCMD)
                ir_review "$ir_file" "run-path" "RUN line $line_num starts a command through variable expansion '$safety_detail'. dock2flox did not execute it because Dockerfile ENV/ARG expansion could resolve to a path-addressed host command; review manually." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: command-position variable expansion not executed by dock2flox; review manually: $(_single_line_preview "$run_body")" "$line_num"
                return 0
                ;;
            LOOP)
                ir_review "$ir_file" "run-timeout" "RUN line $line_num contains an obvious non-terminating shell loop ($safety_detail); active extraction skipped before invoking Bash." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: obvious non-terminating loop not interpreted; review manually: $(_single_line_preview "$run_body")" "$line_num"
                return 0
                ;;
            FUNCTION)
                ir_review "$ir_file" "run-function" "RUN line $line_num defines a shell function. dock2flox did not execute it because function bodies can hide path-addressed or variable-expanded host commands; review manually." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: shell function not interpreted by dock2flox; review manually: $(_single_line_preview "$run_body")" "$line_num"
                return 0
                ;;
        esac
    fi

    # Honor Docker SHELL enough to avoid false positives. Linux Docker defaults
    # to /bin/sh -c; Bash-only syntax under /bin/sh would fail in the container,
    # so it must not be mined for active packages. For unknown/custom shells,
    # preserve the RUN for review rather than guessing.
    case "$shell_kind" in
        sh)
            if ! _run_body_posix_syntax_ok "$run_body"; then
                ir_review "$ir_file" "run-shell" "RUN line $line_num was not analyzed as active because Docker SHELL ${current_shell_desc:-/bin/sh -c} rejects its syntax; review manually." "$line_num"
                ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: not analyzed under Docker SHELL ${current_shell_desc:-/bin/sh -c}: $(_single_line_preview "$run_body")" "$line_num"
                return 0
            fi
            ;;
        bash)
            :
            ;;
        *)
            ir_review "$ir_file" "run-shell" "RUN line $line_num uses unsupported Docker SHELL ${current_shell_desc:-unknown}; active extraction skipped to avoid incorrect packages." "$line_num"
            ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: unsupported Docker SHELL ${current_shell_desc:-unknown}; review manually: $(_single_line_preview "$run_body")" "$line_num"
            return 0
            ;;
    esac

    if _run_body_can_use_conservative_fast_path "$run_body"; then
        _parse_run_conservative "$run_body" "$ir_file" "$line_num" "0"
        return 0
    fi

    # Prefer Bash itself as the shell interpreter. It expands variables, walks
    # conditionals/case/loops, and respects quotes/heredocs. The interpreter
    # stubs known package-manager commands and records argv instead of executing
    # host mutations. If it cannot produce useful events, fall back to the
    # conservative splitter only for syntactically simple, predicate-free RUNs.
    local interpreted=0
    if declare -f interpret_run_body >/dev/null 2>&1; then
        local events_file env_file
        events_file=$(dock2flox_mktemp)
        env_file=$(dock2flox_mktemp)
        _write_run_env_file "$env_file"
        if interpret_run_body "$run_body" "$events_file" "${pkg_manager:-unknown}" "${current_arch:-x86_64}" "$shell_kind" "$env_file"; then
            if _parse_interpreted_run_events "$events_file" "$ir_file" "$line_num" "0"; then
                interpreted=1
            fi
        fi
    fi

    if [[ "$interpreted" -eq 1 ]]; then
        return 0
    fi

    if _run_body_contains_control_flow_or_predicates "$run_body"; then
        ir_review "$ir_file" "run-dynamic" "RUN line $line_num contains control flow or predicates that were not safely interpreted; active extraction skipped." "$line_num"
        ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: dynamic shell not analyzed; review manually: $(_single_line_preview "$run_body")" "$line_num"
        return 0
    fi

    _parse_run_conservative "$run_body" "$ir_file" "$line_num" "0"
}

_single_line_preview() {
    local text="$1"
    text="${text//$'\n'/; }"
    if [[ ${#text} -gt 240 ]]; then
        text="${text:0:237}..."
    fi
    printf '%s' "$text"
}

_run_body_has_bashism() {
    local body="$1"
    # Detect bash-specific syntax that is NOT valid POSIX sh:
    # 1. Array assignment: varname=(...)
    [[ "$body" =~ [A-Za-z_][A-Za-z0-9_]*[[:space:]]*=\( ]] && return 0
    # 2. Array expansion: ${var[@]} or ${var[*]}
    [[ "$body" == *'${'*'[@]}'* || "$body" == *'${'*'[*]}'* ]] && return 0
    # 3. Array index: ${var[0]}
    [[ "$body" =~ \$\{[A-Za-z_][A-Za-z0-9_]*\[[0-9]+\]\} ]] && return 0
    # 4. [[ ]] compound test (when under /bin/sh, this is bash-only)
    [[ "$body" == *'[['*']]'* ]] && return 0
    return 1
}

_run_body_safe_subset_issue() {
    local body="$1" shell_kind="${2:-sh}"
    local compact tmp
    compact=" ${body//$'\n'/ ; } "

    # Safe-subset gate: host Bash may only run modeled command words and
    # supported shell syntax. Unknown command words and unmodelled Bash builtins
    # are review-only. Existing scanners remain as defense-in-depth.
    if [[ "$compact" =~ [A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{ ]] || [[ "$compact" =~ (^|[[:space:];&|])function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{ ]]; then printf 'run-function\tshell function definition\n'; return 0; fi
    if [[ "$compact" =~ (^|[[:space:];&|])time([[:space:];&|]|$) ]]; then printf 'run-unsupported\tunsupported shell control form: time\n'; return 0; fi
    if [[ "$compact" =~ (^|[[:space:];&|])!([[:space:];&|]|$) ]]; then printf 'run-unsupported\tunsupported shell control form: !\n'; return 0; fi
    if [[ "$compact" =~ (^|[[:space:];&|])coproc([[:space:];&|]|$) ]]; then printf 'run-unsupported\tunsupported shell control form: coproc\n'; return 0; fi
    if [[ "$compact" =~ (^|[[:space:];&|])\{ ]] || [[ "$compact" =~ \}([[:space:];&|]|$) ]]; then printf 'run-unsupported\tbrace command group is review-only\n'; return 0; fi
    if [[ "$compact" =~ (^|[[:space:];&|])\( ]]; then printf 'run-unsupported\tsubshell/group syntax is review-only\n'; return 0; fi
    if [[ "$body" == *'$('* ]]; then tmp="$body"; tmp="${tmp//\$(uname -m)/}"; tmp="${tmp//\$(uname --machine)/}"; tmp="${tmp//\$(uname -s)/}"; tmp="${tmp//\$(uname)/}"; tmp="${tmp//\$(id -u)/}"; tmp="${tmp//\$(id -g)/}"; tmp="${tmp//\$(whoami)/}"; [[ "$tmp" == *'$('* ]] && { printf 'run-unsupported\tunsupported command substitution\n'; return 0; }; fi
    if _run_body_has_unsafe_shell_effects "$body"; then printf 'run-unsupported\tredirection or process substitution is review-only\n'; return 0; fi
    [[ "$body" == *'<('* || "$body" == *'>('* ]] && { printf 'run-unsupported\tprocess substitution is review-only\n'; return 0; }
    if [[ "$compact" =~ (^|[[:space:];&|])command[[:space:]]+ ]] && ! [[ "$compact" =~ (^|[[:space:];&|])command[[:space:]]+(-v|-V)[[:space:]]+[A-Za-z0-9_.+-]+([[:space:];&|]|$) ]]; then printf 'run-path\tcommand wrapper dispatch is review-only\n'; return 0; fi
    [[ "$compact" =~ (^|[[:space:];&|])builtin[[:space:]]+ ]] && { printf 'run-path\tbuiltin wrapper dispatch is review-only\n'; return 0; }
    [[ "$compact" =~ (^|[[:space:];&|])(sudo|doas)([[:space:];&|]|$) ]] && { printf 'run-path\twrapper command is review-only\n'; return 0; }
    [[ "$compact" =~ (^|[[:space:];&|])(bash|sh)[[:space:]]+-c([[:space:]]|$) ]] && { printf 'run-path\tshell -c wrapper is review-only\n'; return 0; }
    if [[ "$compact" =~ (^|[[:space:];&|])(eval|source)([[:space:];&|]|$) ]] || [[ "$compact" =~ (^|[;&|])([[:space:]]*)\.[[:space:]]+ ]]; then printf 'run-unsupported\tunsafe shell builtin is review-only\n'; return 0; fi
    [[ "$compact" =~ (^|[[:space:];&|])(PATH|BASH_ENV|ENV|SHELLOPTS|BASHOPTS)= ]] && { printf 'run-unsupported\tcommand execution environment override is review-only\n'; return 0; }

    # Let modeled case bodies run through the existing stub interpreter; path and
    # wrapper hazards have already been rejected and interpreter stubs remain as backstops.
    [[ "$compact" == *" case "* && "$compact" == *" esac "* ]] && return 1

    local normalized token expect_cmd=1
    local unsafe_builtins=" kill mapfile typeset enable hash trap alias unalias "
    local modeled=" apt-get apt apk yum dnf add-apt-repository apt-key dpkg gpg yum-config-manager rpm pip pip3 uv npm npx corepack python python3 virtualenv poetry node pnpm yarn ruby bundle bundler gem php cargo rustup go composer java mvn gradle ./mvnw ./gradlew make cmake curl wget sh bash uname id whoami test [ true false : echo tee mkdir command rm cp mv ln touch chmod chown chgrp install tar unzip gzip gunzip xz bzip2 bunzip2 cat sed awk grep egrep fgrep head tail wc sort cut tr yes find file stat readlink realpath basename dirname which ls pwd rmdir mktemp printf sha256sum sha512sum md5sum sha1sum groupadd useradd adduser addgroup usermod ldconfig update-ca-certificates locale-gen update-alternatives dpkg-reconfigure sync sleep date env xargs export unset cd pushd popd set shopt declare readonly local read exec shift break continue return noop git svn hg rsync ssh scp docker podman kubectl helm terraform ansible jq yq nc ncat openssl ca-certificates libpq-dev libssl-dev pkg-config build-essential "
    normalized="$body"; normalized="${normalized//$'\n'/ ; }"; normalized="${normalized//&&/ ; }"; normalized="${normalized//||/ ; }"; normalized="${normalized//|/ ; }"; normalized="${normalized//;/ ; }"
    for token in $normalized; do
        # Strip surrounding quotes from token for matching
        local bare="$token"
        bare="${bare#\"}"
        bare="${bare%\"}"
        bare="${bare#\'}"
        bare="${bare%\'}"

        case "$bare" in ';'|'then'|'else'|'elif'|'do'|']]') expect_cmd=1; continue ;; 'fi'|'done'|'esac') expect_cmd=0; continue ;; 'if'|'while'|'until') expect_cmd=1; continue ;; 'for') expect_cmd=0; continue ;; 'case'|'in'|'[[') expect_cmd=0; continue ;; *')') expect_cmd=1; continue ;; esac
        if [[ "$expect_cmd" -eq 1 ]]; then
            case "$bare" in [A-Za-z_][A-Za-z0-9_]*=*) case "$bare" in PATH=*|BASH_ENV=*|ENV=*|SHELLOPTS=*|BASHOPTS=*) printf 'run-unsupported\tcommand execution environment override is review-only\n'; return 0 ;; esac; continue ;; esac
            case "$bare" in '$'*|'${'*) printf 'run-path\tcommand-position variable expansion: %s\n' "$bare"; return 0 ;; esac
            case "$bare" in */*) case "$bare" in ./mvnw|./gradlew|*://*) : ;; *) printf 'run-path\tpath-addressed command: %s\n' "$bare"; return 0 ;; esac ;; esac
            [[ "$unsafe_builtins" == *" $bare "* ]] && { printf 'run-unsupported\tunmodelled Bash builtin is review-only: %s\n' "$bare"; return 0; }
            [[ "$modeled" != *" $bare "* ]] && { printf 'run-unsupported\tunmodelled command word is review-only: %s\n' "$bare"; return 0; }
            if [[ "$bare" == "command" ]]; then case "$normalized" in *"command -v "*|*"command -V "*) : ;; *) printf 'run-path\tcommand wrapper dispatch is review-only\n'; return 0 ;; esac; fi
            expect_cmd=0
        fi
    done
    return 1
}

_run_body_posix_syntax_ok() {
    local body="$1"
    if ! command -v sh >/dev/null 2>&1; then
        return 1
    fi
    local syntax_file
    syntax_file=$(dock2flox_mktemp)
    printf '%s\n' "$body" > "$syntax_file"
    sh -n "$syntax_file" >/dev/null 2>&1
}

_run_body_safety_issue() {
    local body="$1"
    local compact segments segment token next rest inner
    compact=" ${body//$'\n'/ ; } "

    case "$compact" in
        *'while true;'*'do'*|*'while true do'*|*'while :;'*'do'*|*'while : do'*|*'until false;'*'do'*|*'until false do'*)
            case "$compact" in
                *'while true;'*|*'while true do'*) printf 'LOOP\twhile true loop\n' ;;
                *'while :;'*|*'while : do'*) printf 'LOOP\twhile : loop\n' ;;
                *) printf 'LOOP\tuntil false loop\n' ;;
            esac
            return 0
            ;;
        *'for (( ; ; ))'*|*'for ((;;))'*)
            printf 'LOOP\tfor (( ; ; )) loop\n'
            return 0
            ;;
    esac

    # Shell functions can defer execution of path-addressed commands or
    # command-position variable expansions until after the static scanner has
    # accepted the RUN body. Host Bash would then execute the function body.
    # Until dock2flox has a true non-executing shell AST interpreter, treat any
    # function definition as review-only and do not invoke Bash for that RUN.
    if [[ "$compact" =~ [A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{ ]] || [[ "$compact" =~ (^|[[:space:];&|])function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{ ]]; then
        printf 'FUNCTION\tshell function definition\n'
        return 0
    fi

    # Cheap prefilter: most RUN bodies contain path arguments or URLs, but
    # command-position variable expansions such as `$CMD /tmp/x` are also
    # safety-sensitive because Bash may expand them into slash-addressed host
    # binaries. If neither slash nor variable expansion is present, there is
    # nothing for this scanner to reject.
    [[ "$compact" == */* || "$compact" == *'$'* ]] || return 0

    # Split on command separators and control-flow command-introducing words.
    # This is conservative by design and avoids invoking Bash or expensive regex
    # matching on URL-heavy package source lines.
    segments=$(printf '%s\n' "$compact" | sed -E 's/(\&\&|\|\||[;|()])/\n/g; s/[[:space:]](then|do|else)[[:space:]]/\n/g')
    while IFS= read -r segment; do
        segment="${segment#"${segment%%[![:space:]]*}"}"
        segment="${segment%"${segment##*[![:space:]]}"}"
        [[ -z "$segment" ]] && continue

        # Drop simple leading environment assignments.
        while [[ "$segment" =~ ^[A-Za-z_][A-Za-z0-9_]*=([^[:space:]]+)[[:space:]]+(.+)$ ]]; do
            segment="${BASH_REMATCH[2]}"
        done

        token="${segment%%[[:space:]]*}"
        rest="${segment#"$token"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$token" in
            if|then|else|elif|fi|for|while|until|case|esac|do|done|function|'!')
                continue
                ;;
            sudo|doas)
                next="${rest%%[[:space:]]*}"
                token="$next"
                rest="${rest#"$next"}"
                rest="${rest#"${rest%%[![:space:]]*}"}"
                ;;
            env)
                while [[ -n "$rest" ]]; do
                    next="${rest%%[[:space:]]*}"
                    case "$next" in
                        --|-i|--ignore-environment|[A-Za-z_][A-Za-z0-9_]*=*)
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            continue
                            ;;
                        -* )
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            # Skip one possible flag operand.
                            next="${rest%%[[:space:]]*}"
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            continue
                            ;;
                    esac
                    token="$next"
                    rest="${rest#"$next"}"
                    rest="${rest#"${rest%%[![:space:]]*}"}"
                    break
                done
                ;;
            command)
                while [[ -n "$rest" ]]; do
                    next="${rest%%[[:space:]]*}"
                    case "$next" in
                        --)
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            token="${rest%%[[:space:]]*}"
                            rest="${rest#"$token"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            break
                            ;;
                        -v|-V|-p)
                            token=""
                            break
                            ;;
                        -* )
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            continue
                            ;;
                        *)
                            token="$next"
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            break
                            ;;
                    esac
                done
                ;;
            builtin)
                next="${rest%%[[:space:]]*}"
                if [[ "$next" == "command" ]]; then
                    rest="${rest#"$next"}"
                    rest="${rest#"${rest%%[![:space:]]*}"}"
                    while [[ -n "$rest" ]]; do
                        next="${rest%%[[:space:]]*}"
                        case "$next" in
                            --)
                                rest="${rest#"$next"}"
                                rest="${rest#"${rest%%[![:space:]]*}"}"
                                token="${rest%%[[:space:]]*}"
                                rest="${rest#"$token"}"
                                rest="${rest#"${rest%%[![:space:]]*}"}"
                                break
                                ;;
                            -v|-V|-p)
                                token=""
                                break
                                ;;
                            -* )
                                rest="${rest#"$next"}"
                                rest="${rest#"${rest%%[![:space:]]*}"}"
                                continue
                                ;;
                            *)
                                token="$next"
                                rest="${rest#"$next"}"
                                rest="${rest#"${rest%%[![:space:]]*}"}"
                                break
                                ;;
                        esac
                    done
                else
                    token=""
                fi
                ;;
            xargs)
                while [[ -n "$rest" ]]; do
                    next="${rest%%[[:space:]]*}"
                    case "$next" in
                        --)
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            token="${rest%%[[:space:]]*}"
                            rest="${rest#"$token"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            break
                            ;;
                        -0|-r|--no-run-if-empty|-t|-p)
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            continue
                            ;;
                        -n|-P|-I|--max-args|--max-procs|--replace)
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            next="${rest%%[[:space:]]*}"
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            continue
                            ;;
                        -* )
                            token=""
                            break
                            ;;
                        *)
                            token="$next"
                            rest="${rest#"$next"}"
                            rest="${rest#"${rest%%[![:space:]]*}"}"
                            break
                            ;;
                    esac
                done
                ;;
        esac

        # A variable expansion in command position is unsafe to interpret.
        # Dockerfile ENV/ARG state can make `$CMD` or `${CMD}` expand to an
        # absolute or relative path command after this scanner runs, causing
        # Bash to bypass PATH and execute an analyzer-host binary/script.
        # Variables in arguments to a modeled command are still allowed, e.g.
        # `apt-get install -y $PKGS`.
        case "$token" in
            '$'*|'"$'*|"'$"*)
                printf 'VARCMD\t%s\n' "$token"
                return 0
                ;;
        esac

        case "$token" in
            ./mvnw|./gradlew|'')
                ;;
            */*)
                case "$token" in
                    *://*) : ;;
                    *) printf 'PATH\t%s\n' "$token"; return 0 ;;
                esac
                ;;
        esac

        # Handle shell -c strings conservatively: if the quoted inner script
        # starts with a path-addressed command, do not eval it in the interpreter.
        case "$token" in
            bash|sh)
                case "$segment" in
                    *' -c '*"'"*"'"*)
                        inner="${segment#* -c }"
                        inner="${inner#\'}"; inner="${inner%%\'*}"
                        inner="${inner#"${inner%%[![:space:]]*}"}"
                        next="${inner%%[[:space:];|&()]*}"
                        case "$next" in
                            '$'*|'"$'*|"'$"*) printf 'VARCMD\t%s\n' "$next"; return 0 ;;
                            ./mvnw|./gradlew|'') : ;;
                            */*) printf 'PATH\t%s\n' "$next"; return 0 ;;
                        esac
                        ;;
                    *' -c "'*)
                        inner="${segment#* -c \"}"
                        inner="${inner%%\"*}"
                        inner="${inner#"${inner%%[![:space:]]*}"}"
                        next="${inner%%[[:space:];|&()]*}"
                        case "$next" in
                            '$'*|'"$'*|"'$"*) printf 'VARCMD\t%s\n' "$next"; return 0 ;;
                            ./mvnw|./gradlew|'') : ;;
                            */*) printf 'PATH\t%s\n' "$next"; return 0 ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done <<< "$segments"
}


_run_body_can_use_conservative_fast_path() {
    local body="$1" first bt sq dq
    # Fast path only for static command text. Anything involving expansion,
    # quoting, predicates, shell functions, or control flow must go through the
    # shell interpreter so Dockerfile semantics are not guessed by text splitting.
    bt=$'\x60'
    sq="'"
    dq='"'
    [[ "$body" == *'$'* ]] && return 1
    [[ "$body" == *"$bt"* ]] && return 1
    [[ "$body" == *"$dq"* ]] && return 1
    [[ "$body" == *"$sq"* ]] && return 1
    [[ "$body" == *'['* || "$body" == *']'* ]] && return 1
    [[ "$body" == *'('* || "$body" == *')'* ]] && return 1
    [[ "$body" == *'{'* || "$body" == *'}'* ]] && return 1
    [[ "$body" == *'<'* || "$body" == *'>'* ]] && return 1
    case " $body " in
        *" if "*|*" then "*|*" else "*|*" fi "*|*" case "*|*" esac "*|*" for "*|*" do "*|*" done "*|*" while "*|*" until "*|*" function "*)
            return 1
            ;;
    esac
    first="${body%%[[:space:];&|]*}"
    case "$first" in
        apt-get|apt|apk|yum|dnf|pip|pip3|uv|npm|npx|corepack|curl|wget|mkdir|python|python3|virtualenv|poetry|pnpm|yarn|bundle|bundler|gem|composer|mvn|./mvnw|gradle|./gradlew|cargo|rustup|go)
            return 0
            ;;
    esac
    return 1
}

_run_body_contains_control_flow_or_predicates() {
    local body="$1" bt
    bt=$'\x60'
    [[ "$body" == *'$('* ]] && return 0
    [[ "$body" == *"$bt"* ]] && return 0
    case "$body" in
        if\ *|*' if '*|*' then '*|*' else '*|*' fi'*|case\ *|*' case '*|*' esac'*|for\ *|*' for '*|while\ *|*' while '*|until\ *|*' until '*|*'['*|*' test '*|*' command -v '*)
            return 0
            ;;
    esac
    return 1
}

_parse_run_conservative() {
    local run_body="$1" ir_file="$2" line_num="$3" installer_found="${4:-0}"

    # Split on common separators as a fallback only. Complex control flow should
    # normally be handled by _parse_interpreted_run_events above.
    local -a commands=()
    _split_run_commands "$run_body" commands

    local cmd
    for cmd in "${commands[@]}"; do
        # Trim whitespace
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        cmd="${cmd%"${cmd##*[![:space:]]}"}"
        [[ -z "$cmd" ]] && continue

        _parse_run_command_text "$cmd" "$ir_file" "$line_num" "$installer_found"
    done
}

_parse_run_command_text() {
    local cmd="$1" ir_file="$2" line_num="$3" installer_found="${4:-0}"
    local command_installer_found=0

    # Skip if matches skip patterns
    if _should_skip_run "$cmd"; then
        return 0
    fi

    # Detect active downloader invocations for well-known installer scripts. The
    # detector tokenizes the command text and only accepts URLs passed to curl or
    # wget, so quoted prose does not create package entries.
    if _detect_known_installer_in_command_text "$cmd" "$ir_file" "$line_num"; then
        command_installer_found=1
    fi

    # Detect package-source configuration and external package artifacts before
    # package installs. These often explain why a package exists in Docker but
    # not in the public Flox catalog.
    _detect_package_source_in_command_text "$cmd" "$ir_file" "$line_num" || true

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
    elif _extract_language_lifecycle_text "$cmd" "$ir_file" "$line_num"; then
        :
    elif [[ "$cmd" =~ corepack[[:space:]]+enable ]]; then
        _extract_corepack_enable "$cmd" "$ir_file" "$line_num"
    elif [[ "$cmd" =~ mkdir[[:space:]]+-p ]]; then
        _extract_mkdir "$cmd" "$ir_file" "$line_num"
    elif [[ "$cmd" =~ python.*-m[[:space:]]+venv || "$cmd" =~ virtualenv ]]; then
        _extract_venv "$cmd" "$ir_file" "$line_num"
    elif [[ "$installer_found" -eq 0 && "$command_installer_found" -eq 0 ]]; then
        # Generic RUN command - check if it's setup-like
        _extract_generic_run "$cmd" "$ir_file" "$line_num"
    fi
}

_parse_interpreted_run_events() {
    local events_file="$1" ir_file="$2" line_num="$3" installer_found="${4:-0}"

    [[ ! -s "$events_file" ]] && return 1

    local uncertain=0
    if grep -q '^UNCERTAIN' "$events_file" 2>/dev/null || false; then
        uncertain=1
    fi

    # If any predicate was unmodelled, the executed command stream may contain a
    # concrete branch chosen only because the stubbed test returned false. In
    # that case, do not emit branch-specific packages as active installs.
    if [[ "$uncertain" -eq 1 ]]; then
        ir_review "$ir_file" "run-predicate" "RUN line $line_num contains unmodelled shell predicates; branch-specific package extraction skipped." "$line_num"
        ir_hook "$ir_file" "$((2000 + line_num))" "# RUN: dynamic shell predicates not modelled; review original Dockerfile line $line_num" "$line_num"
        return 0
    fi

    local handled=0
    local line
    while IFS= read -r line; do
        if _parse_interpreted_run_event "$line" "$ir_file" "$line_num" "$installer_found"; then
            handled=1
        fi
    done < "$events_file"

    [[ "$handled" -eq 1 ]] && return 0
    return 1
}

_parse_interpreted_run_event() {
    local line="$1" ir_file="$2" line_num="$3" installer_found="${4:-0}"

    local -a fields=()
    IFS=$'\t' read -r -a fields <<< "$line"
    [[ ${#fields[@]} -lt 2 ]] && return 1
    [[ "${fields[0]}" != "CMD" ]] && return 1

    local -a argv=()
    local field
    for field in "${fields[@]:1}"; do
        argv+=("$(_shell_event_decode "$field")")
    done

    [[ ${#argv[@]} -eq 0 ]] && return 1

    local cmd="${argv[0]}"
    local cmd_text
    cmd_text=$(_join_shell_words "${argv[@]}")

    _detect_package_source_from_argv "$ir_file" "$line_num" "${argv[@]}" || true

    case "$cmd" in
        apt-get|apt)
            if _argv_has_word "install" "${argv[@]:1}"; then
                _extract_packages_after_subcommand "apt" "install" "$ir_file" "$line_num" "${argv[@]:1}"
                return 0
            fi
            ;;
        apk)
            if _argv_has_word "add" "${argv[@]:1}"; then
                _extract_packages_after_subcommand "apk" "add" "$ir_file" "$line_num" "${argv[@]:1}"
                return 0
            fi
            ;;
        yum|dnf)
            if _argv_has_word "install" "${argv[@]:1}"; then
                _extract_packages_after_subcommand "yum" "install" "$ir_file" "$line_num" "${argv[@]:1}"
                return 0
            fi
            ;;
        pip|pip3)
            if [[ " ${argv[*]:1} " == *" install "* ]]; then
                _extract_pip_install_argv "$ir_file" "$line_num" "${argv[@]}"
                return 0
            fi
            ;;
        uv)
            if [[ ${#argv[@]} -ge 3 && "${argv[1]}" == "pip" && "${argv[2]}" == "install" ]]; then
                _extract_pip_install_argv "$ir_file" "$line_num" "${argv[@]}"
                return 0
            fi
            ;;
        npm)
            if _npm_argv_is_global_install "${argv[@]:1}"; then
                local npm_cmd
                npm_cmd=$(_npm_global_canonical_command "${argv[@]:1}")
                _extract_npm_global "$npm_cmd" "$ir_file" "$line_num"
                return 0
            fi
            if _extract_node_lifecycle_argv "$ir_file" "$line_num" "npm" "${argv[@]}"; then
                return 0
            fi
            ;;
        yarn|pnpm)
            if _extract_node_lifecycle_argv "$ir_file" "$line_num" "$cmd" "${argv[@]}"; then
                return 0
            fi
            ;;
        bundle|bundler)
            if _extract_bundler_lifecycle_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        gem)
            if _extract_gem_lifecycle_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        composer)
            if _extract_composer_lifecycle_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        mvn|mvnw|./mvnw|gradle|gradlew|./gradlew)
            if _extract_java_lifecycle_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        cargo)
            if _extract_cargo_lifecycle_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        go)
            if _extract_go_lifecycle_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        corepack)
            if [[ ${#argv[@]} -ge 2 && "${argv[1]}" == "enable" ]]; then
                _extract_corepack_enable "$cmd_text" "$ir_file" "$line_num"
                return 0
            fi
            ;;
        curl|wget)
            _detect_package_source_from_argv "$ir_file" "$line_num" "${argv[@]}" || true
            if _detect_known_installer_from_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        add-apt-repository|apt-key|gpg|dpkg|yum-config-manager|rpm|tee|echo)
            if _detect_package_source_from_argv "$ir_file" "$line_num" "${argv[@]}"; then
                return 0
            fi
            ;;
        mkdir)
            if _argv_has_word "-p" "${argv[@]:1}" || _argv_has_word "--parents" "${argv[@]:1}"; then
                _extract_mkdir "$cmd_text" "$ir_file" "$line_num"
                return 0
            fi
            ;;
        python|python3|virtualenv)
            if [[ "$cmd_text" =~ python.*-m[[:space:]]+venv || "$cmd" == "virtualenv" ]]; then
                _extract_venv "$cmd_text" "$ir_file" "$line_num"
                return 0
            fi
            ;;
        eval|exec|source|.)
            ir_hook "$ir_file" "200" "# RUN: dynamic shell command not analyzed: $cmd_text" "$line_num"
            return 0
            ;;
    esac

    if [[ "$installer_found" -eq 0 && "$cmd" != "curl" && "$cmd" != "wget" ]]; then
        return 1
    fi
    return 1
}

_shell_event_decode() {
    local value="$1"
    value="${value//\\t/$'\t'}"
    value="${value//\\n/$'\n'}"
    value="${value//\\r/$'\r'}"
    value="${value//\\\\/\\}"
    printf '%s' "$value"
}

_join_shell_words() {
    local word out=""
    for word in "$@"; do
        printf -v word '%q' "$word"
        out+="$word "
    done
    printf '%s' "${out% }"
}

_argv_has_word() {
    local needle="$1"
    shift
    local word
    for word in "$@"; do
        [[ "$word" == "$needle" ]] && return 0
    done
    return 1
}

_extract_packages_after_subcommand() {
    local pkg_manager="$1" subcommand="$2" ir_file="$3" line_num="$4"
    shift 4

    local seen_subcommand=0
    local skip_next=0
    local pending_flag=""
    local token
    for token in "$@"; do
        if [[ "$seen_subcommand" -eq 0 ]]; then
            [[ "$token" == "$subcommand" ]] && seen_subcommand=1
            continue
        fi

        if [[ "$skip_next" -eq 1 ]]; then
            case "$pending_flag" in
                --repository|-X|--extra-index-url|--index-url|--trusted-host|--registry|--config|--repofrompath|--setopt)
                    _review_package_source "$ir_file" "$line_num" "$pkg_manager" "$pending_flag $token"
                    ;;
            esac
            pending_flag=""
            skip_next=0
            continue
        fi

        case "$token" in
            --)
                continue
                ;;
            -o|-c|--option|--config-file|--virtual|-t|--target-release|--releasever)
                pending_flag="$token"
                skip_next=1
                continue
                ;;
            --repository|-X|--repo|--repofrompath|--setopt|--enablerepo|--disablerepo)
                pending_flag="$token"
                skip_next=1
                continue
                ;;
            --repository=*|-X*|--repo=*|--repofrompath=*|--setopt=*|--enablerepo=*|--disablerepo=*)
                _review_package_source "$ir_file" "$line_num" "$pkg_manager" "$token"
                continue
                ;;
            --allow-untrusted|--nogpgcheck|--no-gpg-check)
                _review_package_source "$ir_file" "$line_num" "$pkg_manager" "$token"
                continue
                ;;
            -* )
                continue
                ;;
        esac

        [[ -z "$token" ]] && continue

        if _token_is_external_package_artifact "$token"; then
            _review_package_source "$ir_file" "$line_num" "$pkg_manager" "external package artifact: $token"
            continue
        fi

        if [[ "$pkg_manager" != "apk" && "$token" == *"="* ]]; then
            local version="${token#*=}"
            token="${token%%=*}"
            [[ -z "$token" ]] && continue
            map_package "$pkg_manager" "$token" "$ir_file" "$line_num" "$version"
            continue
        fi

        if [[ "$pkg_manager" == "apt" && "$token" == */* && "$token" != ./* && "$token" != /* ]]; then
            _review_package_source "$ir_file" "$line_num" "$pkg_manager" "release-qualified package selector: $token"
            token="${token%%/*}"
        fi

        [[ -z "$token" ]] && continue
        map_package "$pkg_manager" "$token" "$ir_file" "$line_num"
    done
}

_npm_argv_is_global_install() {
    local -a args=("$@")
    [[ ${#args[@]} -eq 0 ]] && return 1
    [[ "${args[0]}" != "install" && "${args[0]}" != "i" ]] && return 1

    local arg
    for arg in "${args[@]:1}"; do
        case "$arg" in
            -g|--global|--location=global)
                return 0
                ;;
        esac
    done
    return 1
}

_npm_global_canonical_command() {
    local -a args=("$@")
    local -a pkgs=()
    local skip_next=0
    local arg
    for arg in "${args[@]:1}"; do
        if [[ "$skip_next" -eq 1 ]]; then
            skip_next=0
            continue
        fi
        case "$arg" in
            -g|--global|--location=global)
                continue
                ;;
            --location|--registry|--npm-registry-server)
                skip_next=1
                continue
                ;;
            --*)
                continue
                ;;
            -* )
                continue
                ;;
            *)
                pkgs+=("$arg")
                ;;
        esac
    done

    printf 'npm install -g'
    local pkg
    for pkg in "${pkgs[@]}"; do
        printf ' %q' "$pkg"
    done
}

_split_run_commands() {
    local body="$1"
    local -n _out_commands="$2"
    # Split common Dockerfile RUN chains into independently detectable commands.
    # This is intentionally simple shell parsing; complex control flow falls back
    # to generic hook comments.
    local delim=$'\x1f'  # unit separator
    local replaced="${body// && /$delim}"
    replaced="${replaced//&&/$delim}"
    replaced="${replaced//; /$delim}"
    replaced="${replaced//;/$delim}"
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

# --- Pip mode-aware classification ---
# Shared by _extract_pip_install and _extract_pip_install_argv

_classify_pip_package() {
    local pkg="$1" nixpkgs_path="$2" ir_file="$3" line_num="$4"
    local -n _unmapped_ref="$5"
    local pip_mode="${DOCK2FLOX_PIP_MODE:-project}"

    # Always skip (pip, setuptools, wheel)
    if [[ "$nixpkgs_path" == "_skip_" ]]; then
        log_verbose "pip: skipping $pkg (included with python)"
        return 0
    fi

    # Mode: requirements — everything goes to project graph, nothing in [install]
    if [[ "$pip_mode" == "requirements" ]]; then
        _unmapped_ref+=("$pkg")
        log_verbose "pip: $pkg -> project graph (--pip=requirements)"
        return 0
    fi

    # Mode: cuda — check cuda_packages.map first
    if [[ "$pip_mode" == "cuda" ]]; then
        local cuda_path
        cuda_path=$(_lookup_cuda_package "$pkg")
        if [[ -n "$cuda_path" ]]; then
            # Defer CUDA emit — collect into IR now; dedup happens at emit time
            # because we can't know ordering of pip install args
            local cuda_id="${cuda_path##*.}"
            ir_install "$ir_file" "$cuda_id" "$cuda_path" "" "" "EXACT" "$line_num" "CUDA-accelerated via flox-cuda"
            log_verbose "pip: $pkg -> $cuda_path (CUDA)"
            return 0
        fi
        # Fall through to project-mode logic for non-CUDA packages
    fi

    # Mode: flox — promote _project_ entries to [install]
    if [[ "$pip_mode" == "flox" && "$nixpkgs_path" == "_project_" ]]; then
        local candidate="python313Packages.$pkg"
        ir_install "$ir_file" "$pkg" "$candidate" "" "" "HIGH" "$line_num" "promoted to [install] by --pip=flox"
        log_verbose "pip: $pkg -> $candidate (promoted by --pip=flox)"
        return 0
    fi

    # Default classification (project mode, or cuda/flox fallthrough)
    if [[ "$nixpkgs_path" == "_project_" ]]; then
        _unmapped_ref+=("$pkg")
        log_verbose "pip: $pkg -> project graph (not Flox [install])"
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
        _unmapped_ref+=("$pkg")
        log_verbose "pip: $pkg -> unmapped (will remain as hook)"
    fi
}

_lookup_cuda_package() {
    local pkg="$1"
    local cuda_map="$DOCK2FLOX_DATA/cuda_packages.map"
    [[ ! -f "$cuda_map" ]] && return 0
    awk -F'\t' -v p="$pkg" 'tolower($1) == tolower(p) && $1 !~ /^#/ {print $2; exit}' "$cuda_map"
}

_cuda_pkg_already_provided() {
    local pkg="$1" ir_file="$2"
    local cuda_map="$DOCK2FLOX_DATA/cuda_packages.map"
    [[ ! -f "$cuda_map" ]] && return 1

    local provider path provides
    while IFS=$'\t' read -r provider path provides; do
        [[ -z "$provider" || "$provider" == "#"* ]] && continue
        [[ -z "$provides" ]] && continue
        # If $pkg is in the provides list of another package
        if [[ " $provides " == *" $pkg "* ]]; then
            # Check if that provider is already in the IR
            if { grep "^INSTALL${IR_DELIM}" "$ir_file" 2>/dev/null || true; } | grep -q "${IR_DELIM}${path}${IR_DELIM}"; then
                return 0
            fi
        fi
    done < "$cuda_map"
    return 1
}

_extract_pip_install() {
    local cmd="$1" ir_file="$2" line_num="$3"
    local map_file="$DOCK2FLOX_DATA/pip_to_nixpkgs.map"

    local requirement_file=""
    requirement_file=$(_pip_requirement_file "$cmd")

    local installs_local_project=0
    if _pip_installs_local_project "$cmd"; then
        installs_local_project=1
    fi

    if [[ -n "$requirement_file" || "$installs_local_project" -eq 1 ]]; then
        ir_install "$ir_file" "uv" "uv" "" "" "EXACT" "$line_num" "installer for Python project dependencies"
        _emit_python_dependency_hook "$ir_file" "$line_num" "$requirement_file" "$installs_local_project"
    fi

    # Extract package names: strip the command prefix, flags, requirement files,
    # local project specs, and version specifiers.
    local pkg_list
    pkg_list=$(echo "$cmd" | sed -E '
        s/.*(uv[[:space:]]+)?pip[3]?[[:space:]]+install[[:space:]]+//
        s/--requirement(=|[[:space:]]+)[^[:space:]]+//g
        s/-r[[:space:]]+[^[:space:]]+//g
        s/-r[^[:space:]]+//g
        s/(^|[[:space:]])-e[[:space:]]+\.?([[:space:]]|$)/ /g
        s/(^|[[:space:]])\.([[:space:]]|$)/ /g
        s/--[a-z][-a-z]*(=[^ ]+)?//g
        s/-[a-zA-Z]( [^ ]+)?//g
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
        pkg="${pkg#'}"
        pkg="${pkg%'}"

        # Strip version specifiers (>=, <=, ~=, ==, [extras])
        pkg=$(echo "$pkg" | sed -E 's/[><=~!]=?.*//; s/\[.*\]//')
        [[ -z "$pkg" ]] && continue

        # Look up in pip_to_nixpkgs.map
        nixpkgs_path=""
        if [[ -f "$map_file" ]]; then
            nixpkgs_path=$(awk -F'	' -v p="$pkg" 'tolower($1) == tolower(p) && !found {print $2; found=1}' "$map_file")
        fi

        _classify_pip_package "$pkg" "$nixpkgs_path" "$ir_file" "$line_num" unmapped_pkgs
    done

    # Emit remaining unmapped packages as an active uv pip install hook.
    if [[ ${#unmapped_pkgs[@]} -gt 0 ]]; then
        local remaining="${unmapped_pkgs[*]}"
        ir_install "$ir_file" "uv" "uv" "" "" "EXACT" "$line_num" "installer for Python project dependencies"
        ir_hook "$ir_file" "$((1000 + line_num * 10))" "uv pip install --quiet $remaining" "$line_num"
    fi
}

_pip_requirement_file() {
    local cmd="$1"
    local req=""
    req=$(awk '{
        for (i = 1; i <= NF && !found; i++) {
            if ($i == "-r" || $i == "--requirement") { print $(i + 1); found=1 }
            else if ($i ~ /^--requirement=/) { sub(/^--requirement=/, "", $i); print $i; found=1 }
            else if ($i ~ /^-r[^[:space:]]+/) { print substr($i, 3); found=1 }
        }
    }' <<< "$cmd")
    req="${req#\"}"
    req="${req%\"}"
    req="${req#'}"
    req="${req%'}"
    printf '%s' "$req"
}

_pip_installs_local_project() {
    local cmd="$1"
    local payload
    payload=$(echo "$cmd" | sed -E 's/.*(uv[[:space:]]+)?pip[3]?[[:space:]]+install[[:space:]]+//')

    local token prev=""
    for token in $payload; do
        token="${token#\"}"
        token="${token%\"}"
        token="${token#'}"
        token="${token%'}"
        if [[ "$token" == "." || "$token" == "./" ]]; then
            return 0
        fi
        if [[ "$prev" == "-e" && ( "$token" == "." || "$token" == "./" ) ]]; then
            return 0
        fi
        prev="$token"
    done
    return 1
}

_emit_python_dependency_hook() {
    local ir_file="$1" line_num="$2" requirement_file="$3" installs_local_project="$4"
    local base=$((1000 + line_num * 10))

    if [[ "$installs_local_project" -eq 1 && -n "$requirement_file" ]]; then
        ir_hook "$ir_file" "$((base + 0))" 'if [ -f pyproject.toml ]; then' "$line_num"
        ir_hook "$ir_file" "$((base + 1))" '  uv sync --quiet' "$line_num"
        ir_hook "$ir_file" "$((base + 2))" "elif [ -f \"$requirement_file\" ]; then" "$line_num"
        ir_hook "$ir_file" "$((base + 3))" "  uv pip install --quiet -r \"$requirement_file\"" "$line_num"
        ir_hook "$ir_file" "$((base + 4))" 'fi' "$line_num"
    elif [[ "$installs_local_project" -eq 1 ]]; then
        ir_hook "$ir_file" "$((base + 0))" 'if [ -f pyproject.toml ]; then' "$line_num"
        ir_hook "$ir_file" "$((base + 1))" '  uv sync --quiet' "$line_num"
        ir_hook "$ir_file" "$((base + 2))" 'fi' "$line_num"
    elif [[ -n "$requirement_file" ]]; then
        ir_hook "$ir_file" "$((base + 0))" "if [ -f \"$requirement_file\" ]; then" "$line_num"
        ir_hook "$ir_file" "$((base + 1))" "  uv pip install --quiet -r \"$requirement_file\"" "$line_num"
        ir_hook "$ir_file" "$((base + 2))" 'fi' "$line_num"
    fi
}

_extract_pip_install_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    local -a argv=("$@")
    local map_file="$DOCK2FLOX_DATA/pip_to_nixpkgs.map"

    local install_index=-1
    local i=0
    while [[ "$i" -lt ${#argv[@]} ]]; do
        if [[ "${argv[$i]}" == "install" ]]; then
            install_index="$i"
            break
        fi
        i=$((i + 1))
    done
    [[ "$install_index" -lt 0 ]] && return 0

    local requirement_file=""
    local installs_local_project=0
    local -a unmapped_pkgs=()
    local skip_next=0 pending_flag="" arg

    i=$((install_index + 1))
    while [[ "$i" -lt ${#argv[@]} ]]; do
        arg="${argv[$i]}"

        if [[ "$skip_next" -eq 1 ]]; then
            case "$pending_flag" in
                -r|--requirement)
                    requirement_file="$arg"
                    ;;
                -e|--editable)
                    [[ "$arg" == "." || "$arg" == "./" ]] && installs_local_project=1
                    if _token_is_external_package_artifact "$arg" || [[ "$arg" == http://* || "$arg" == https://* ]]; then
                        _review_package_source "$ir_file" "$line_num" "pip" "$pending_flag $arg"
                    fi
                    ;;
                --index-url|--extra-index-url|--find-links|--trusted-host|--constraint|-c)
                    _review_package_source "$ir_file" "$line_num" "pip" "$pending_flag $arg"
                    ;;
            esac
            pending_flag=""
            skip_next=0
            i=$((i + 1))
            continue
        fi

        case "$arg" in
            -r|--requirement|-e|--editable|--index-url|--extra-index-url|--find-links|--trusted-host|--constraint|-c)
                pending_flag="$arg"
                skip_next=1
                i=$((i + 1))
                continue
                ;;
            --requirement=*)
                requirement_file="${arg#--requirement=}"
                i=$((i + 1))
                continue
                ;;
            -r*)
                requirement_file="${arg#-r}"
                i=$((i + 1))
                continue
                ;;
            --index-url=*|--extra-index-url=*|--find-links=*|--trusted-host=*|--constraint=*)
                _review_package_source "$ir_file" "$line_num" "pip" "$arg"
                i=$((i + 1))
                continue
                ;;
            --*)
                i=$((i + 1))
                continue
                ;;
            -*)
                i=$((i + 1))
                continue
                ;;
        esac

        if [[ "$arg" == "." || "$arg" == "./" ]]; then
            installs_local_project=1
            i=$((i + 1))
            continue
        fi

        if _token_is_external_package_artifact "$arg" || [[ "$arg" == http://* || "$arg" == https://* ]]; then
            _review_package_source "$ir_file" "$line_num" "pip" "$arg"
            i=$((i + 1))
            continue
        fi

        local pkg="$arg"
        pkg="${pkg#\"}"; pkg="${pkg%\"}"
        pkg="${pkg#\'}"; pkg="${pkg%\'}"
        pkg=$(printf '%s' "$pkg" | sed -E 's/[><=~!]=?.*//; s/\[.*\]//')
        [[ -z "$pkg" ]] && { i=$((i + 1)); continue; }

        local nixpkgs_path=""
        if [[ -f "$map_file" ]]; then
            nixpkgs_path=$(awk -F'\t' -v p="$pkg" 'tolower($1) == tolower(p) && !found {print $2; found=1}' "$map_file")
        fi

        _classify_pip_package "$arg" "$nixpkgs_path" "$ir_file" "$line_num" unmapped_pkgs

        i=$((i + 1))
    done

    if [[ -n "$requirement_file" || "$installs_local_project" -eq 1 ]]; then
        ir_install "$ir_file" "uv" "uv" "" "" "EXACT" "$line_num" "installer for Python project dependencies"
        _emit_python_dependency_hook "$ir_file" "$line_num" "$requirement_file" "$installs_local_project"
    fi

    if [[ ${#unmapped_pkgs[@]} -gt 0 ]]; then
        ir_install "$ir_file" "uv" "uv" "" "" "EXACT" "$line_num" "installer for Python project dependencies"
        local install_line="uv pip install --quiet"
        local pkg quoted
        for pkg in "${unmapped_pkgs[@]}"; do
            printf -v quoted '%q' "$pkg"
            install_line+=" $quoted"
        done
        ir_hook "$ir_file" "$((1000 + line_num * 10))" "$install_line" "$line_num"
    fi
}

_extract_npm_global() {
    local cmd="$1" ir_file="$2" line_num="$3"

    # npm install -g packages stay as hook commands — they're managed by
    # the Node.js ecosystem, not the Flox catalog.
    # Extract package names after -g flag
    local pkg_list
    pkg_list=$(echo "$cmd" | sed -E 's/.*install\s+-g\s+//' | sed -E 's/--[a-z-]+(=[^ ]+)?//g')

    local -a pkgs=()
    local pkg
    for pkg in $pkg_list; do
        [[ -z "$pkg" ]] && continue
        [[ "$pkg" == -* ]] && continue
        pkgs+=("$pkg")
    done

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        local remaining="${pkgs[*]}"
        ir_hook "$ir_file" "$((1000 + line_num * 10))" "npm install -g $remaining" "$line_num"
    fi
}


# --- Language ecosystem lifecycle helpers ---

_language_tool_record() {
    local tool_key="$1"
    local map_file="$DOCK2FLOX_DATA/language_ecosystems.map"
    [[ ! -f "$map_file" ]] && return 1
    awk -F'\t' -v key="$tool_key" '$1 == key && !found {print $2 "\t" $3 "\t" $4; found=1}' "$map_file"
}

_ensure_language_tool() {
    local ir_file="$1" line_num="$2" tool_key="$3"
    local record install_id pkg_path notes
    record=$(_language_tool_record "$tool_key")
    if [[ -z "$record" ]]; then
        ir_review "$ir_file" "language-lifecycle" "No language ecosystem mapping found for $tool_key; add it to data/language_ecosystems.map." "$line_num"
        return 0
    fi
    IFS=$'\t' read -r install_id pkg_path notes <<< "$record"
    ir_install "$ir_file" "$install_id" "$pkg_path" "" "" "EXACT" "$line_num" "$notes"
}

_shell_quote_args() {
    local out="" word quoted
    for word in "$@"; do
        printf -v quoted '%q' "$word"
        out+="$quoted "
    done
    printf '%s' "${out% }"
}

_join_from_index() {
    local start="$1"
    shift
    local -a argv=("$@")
    local -a selected=()
    local i="$start"
    while [[ "$i" -lt ${#argv[@]} ]]; do
        selected+=("${argv[$i]}")
        i=$((i + 1))
    done
    _shell_quote_args "${selected[@]}"
}

_emit_hook_block() {
    local ir_file="$1" line_num="$2" base="$3"
    shift 3
    local line order="$base"
    for line in "$@"; do
        ir_hook "$ir_file" "$order" "$line" "$line_num"
        order=$((order + 1))
    done
}

_emit_language_review() {
    local ir_file="$1" line_num="$2" detail="$3"
    ir_review "$ir_file" "language-lifecycle" "$detail" "$line_num"
}

_has_direct_dependency_args() {
    local start="$1"
    shift
    local -a argv=("$@")
    local i="$start" arg skip_next=0
    while [[ "$i" -lt ${#argv[@]} ]]; do
        arg="${argv[$i]}"
        if [[ "$skip_next" -eq 1 ]]; then
            skip_next=0
            i=$((i + 1))
            continue
        fi
        case "$arg" in
            --)
                i=$((i + 1))
                continue
                ;;
            --prefix|--cache|--registry|--userconfig|--globalconfig|--cwd|--filter|--workspace|--network-timeout)
                skip_next=1
                i=$((i + 1))
                continue
                ;;
            --prefix=*|--cache=*|--registry=*|--userconfig=*|--globalconfig=*|--cwd=*|--filter=*|--workspace=*|--network-timeout=*)
                i=$((i + 1))
                continue
                ;;
            -* )
                i=$((i + 1))
                continue
                ;;
        esac
        [[ -n "$arg" ]] && return 0
        i=$((i + 1))
    done
    return 1
}

_extract_language_lifecycle_text() {
    local cmd="$1" ir_file="$2" line_num="$3"
    local -a words=()
    _shell_words_simple "$cmd" words
    [[ ${#words[@]} -eq 0 ]] && return 1
    local manager="${words[0]##*/}"
    case "$manager" in
        npm|yarn|pnpm)
            _extract_node_lifecycle_argv "$ir_file" "$line_num" "$manager" "${words[@]}"
            return $?
            ;;
        bundle|bundler)
            _extract_bundler_lifecycle_argv "$ir_file" "$line_num" "${words[@]}"
            return $?
            ;;
        gem)
            _extract_gem_lifecycle_argv "$ir_file" "$line_num" "${words[@]}"
            return $?
            ;;
        composer)
            _extract_composer_lifecycle_argv "$ir_file" "$line_num" "${words[@]}"
            return $?
            ;;
        mvn|mvnw|gradle|gradlew|./mvnw|./gradlew)
            _extract_java_lifecycle_argv "$ir_file" "$line_num" "${words[@]}"
            return $?
            ;;
        cargo)
            _extract_cargo_lifecycle_argv "$ir_file" "$line_num" "${words[@]}"
            return $?
            ;;
        go)
            _extract_go_lifecycle_argv "$ir_file" "$line_num" "${words[@]}"
            return $?
            ;;
    esac
    return 1
}

_extract_node_lifecycle_argv() {
    local ir_file="$1" line_num="$2" manager="$3"
    shift 3
    local -a argv=("$@")
    [[ ${#argv[@]} -eq 0 ]] && return 1

    _ensure_language_tool "$ir_file" "$line_num" "nodejs"
    case "$manager" in
        yarn) _ensure_language_tool "$ir_file" "$line_num" "yarn" ;;
        pnpm) _ensure_language_tool "$ir_file" "$line_num" "pnpm" ;;
        npm) _ensure_language_tool "$ir_file" "$line_num" "npm" ;;
    esac

    local sub="${argv[1]:-}"
    [[ -z "$sub" && "$manager" == "yarn" ]] && sub="install"

    case "$manager:$sub" in
        npm:ci)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_hook_block "$ir_file" "$line_num" "$((1200 + line_num * 10))" \
                'if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then' \
                "  npm ci${extra:+ $extra}" \
                'elif [ -f package.json ]; then' \
                '  npm install' \
                'fi'
            return 0
            ;;
        npm:install|npm:i)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            if _has_direct_dependency_args 2 "${argv[@]}"; then
                _emit_language_review "$ir_file" "$line_num" "npm direct dependency install preserved as an activation hook; prefer committing dependencies to package.json/lockfile."
            fi
            _emit_hook_block "$ir_file" "$line_num" "$((1200 + line_num * 10))" \
                'if [ -f package.json ]; then' \
                "  npm install${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        npm:run)
            local script="${argv[2]:-}"
            [[ -z "$script" ]] && return 1
            local extra
            extra=$(_join_from_index 3 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "npm script '$script' is preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1 because Docker build-time scripts may be expensive on activation."
            _emit_hook_block "$ir_file" "$line_num" "$((1210 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f package.json ]; then' \
                "  npm run $script${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        yarn:install|yarn:)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_hook_block "$ir_file" "$line_num" "$((1220 + line_num * 10))" \
                'if [ -f package.json ]; then' \
                "  yarn install${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        yarn:add)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "yarn add mutates project dependency metadata; preserved behind DOCK2FLOX_SYNC_DIRECT_DEPS=1."
            _emit_hook_block "$ir_file" "$line_num" "$((1220 + line_num * 10))" \
                'if [ "${DOCK2FLOX_SYNC_DIRECT_DEPS:-0}" = "1" ] && [ -f package.json ]; then' \
                "  yarn add${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        pnpm:install|pnpm:i)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_hook_block "$ir_file" "$line_num" "$((1230 + line_num * 10))" \
                'if [ -f package.json ]; then' \
                "  pnpm install${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        pnpm:add)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "pnpm add mutates project dependency metadata; preserved behind DOCK2FLOX_SYNC_DIRECT_DEPS=1."
            _emit_hook_block "$ir_file" "$line_num" "$((1230 + line_num * 10))" \
                'if [ "${DOCK2FLOX_SYNC_DIRECT_DEPS:-0}" = "1" ] && [ -f package.json ]; then' \
                "  pnpm add${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        pnpm:run)
            local script="${argv[2]:-}"
            [[ -z "$script" ]] && return 1
            local extra
            extra=$(_join_from_index 3 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "pnpm script '$script' is preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1 because Docker build-time scripts may be expensive on activation."
            _emit_hook_block "$ir_file" "$line_num" "$((1235 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f package.json ]; then' \
                "  pnpm run $script${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        yarn:run)
            local script="${argv[2]:-}"
            [[ -z "$script" ]] && return 1
            local extra
            extra=$(_join_from_index 3 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "yarn script '$script' is preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1 because Docker build-time scripts may be expensive on activation."
            _emit_hook_block "$ir_file" "$line_num" "$((1225 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f package.json ]; then' \
                "  yarn run $script${extra:+ $extra}" \
                'fi'
            return 0
            ;;
    esac

    # Yarn commonly treats `yarn build` as `yarn run build`.
    if [[ "$manager" == "yarn" && -n "$sub" && "$sub" != -* ]]; then
        local extra
        extra=$(_join_from_index 2 "${argv[@]}")
        _emit_language_review "$ir_file" "$line_num" "yarn script '$sub' is preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1 because Docker build-time scripts may be expensive on activation."
        _emit_hook_block "$ir_file" "$line_num" "$((1225 + line_num * 10))" \
            'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f package.json ]; then' \
            "  yarn $sub${extra:+ $extra}" \
            'fi'
        return 0
    fi

    return 1
}

_extract_bundler_lifecycle_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    local -a argv=("$@")
    local sub="${argv[1]:-install}"
    _ensure_language_tool "$ir_file" "$line_num" "ruby"
    _ensure_language_tool "$ir_file" "$line_num" "bundler"
    case "$sub" in
        install|update)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_hook_block "$ir_file" "$line_num" "$((1300 + line_num * 10))" \
                'if [ -f Gemfile ]; then' \
                '  bundle config set path "${BUNDLE_PATH:-$FLOX_ENV_CACHE/bundle}" >/dev/null 2>&1 || true' \
                "  bundle $sub${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        exec)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "bundle exec command preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1."
            _emit_hook_block "$ir_file" "$line_num" "$((1310 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f Gemfile ]; then' \
                "  bundle exec${extra:+ $extra}" \
                'fi'
            return 0
            ;;
    esac
    return 1
}

_extract_gem_lifecycle_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    local -a argv=("$@")
    [[ "${argv[1]:-}" != "install" ]] && return 1
    _ensure_language_tool "$ir_file" "$line_num" "ruby"
    local i=2 pkg found=0
    while [[ "$i" -lt ${#argv[@]} ]]; do
        pkg="${argv[$i]}"
        case "$pkg" in
            -* ) i=$((i + 1)); continue ;;
        esac
        if [[ "$pkg" == "bundler" ]]; then
            _ensure_language_tool "$ir_file" "$line_num" "bundler"
            found=1
        else
            _emit_language_review "$ir_file" "$line_num" "gem install $pkg is not a project lockfile workflow; prefer Gemfile/Bundler or add a reviewed package mapping."
        fi
        i=$((i + 1))
    done
    [[ "$found" -eq 1 ]] && return 0
    return 0
}

_extract_composer_lifecycle_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    local -a argv=("$@")
    local sub="${argv[1]:-install}"
    _ensure_language_tool "$ir_file" "$line_num" "php"
    _ensure_language_tool "$ir_file" "$line_num" "composer"
    case "$sub" in
        install|update)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_hook_block "$ir_file" "$line_num" "$((1400 + line_num * 10))" \
                'if [ -f composer.json ]; then' \
                "  composer $sub${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        dump-autoload|run-script)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "composer $sub command preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1."
            _emit_hook_block "$ir_file" "$line_num" "$((1410 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f composer.json ]; then' \
                "  composer $sub${extra:+ $extra}" \
                'fi'
            return 0
            ;;
    esac
    return 1
}

_extract_java_lifecycle_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    local -a argv=("$@")
    local cmd="${argv[0]##*/}"
    _ensure_language_tool "$ir_file" "$line_num" "jdk"
    case "$cmd" in
        mvn|mvnw)
            _ensure_language_tool "$ir_file" "$line_num" "maven"
            local extra
            extra=$(_join_from_index 1 "${argv[@]}")
            if [[ "$cmd" == "mvnw" ]]; then
                _emit_language_review "$ir_file" "$line_num" "Maven wrapper detected; generated hook uses system mvn from Flox. Review wrapper-specific extensions."
            fi
            _emit_hook_block "$ir_file" "$line_num" "$((1500 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f pom.xml ]; then' \
                "  mvn${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        gradle|gradlew)
            _ensure_language_tool "$ir_file" "$line_num" "gradle"
            local extra
            extra=$(_join_from_index 1 "${argv[@]}")
            if [[ "$cmd" == "gradlew" ]]; then
                _emit_language_review "$ir_file" "$line_num" "Gradle wrapper detected; generated hook uses system gradle from Flox. Review wrapper-specific plugins and distribution URLs."
            fi
            _emit_hook_block "$ir_file" "$line_num" "$((1510 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && { [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -f settings.gradle ] || [ -f settings.gradle.kts ]; }; then' \
                "  gradle${extra:+ $extra}" \
                'fi'
            return 0
            ;;
    esac
    return 1
}

_extract_cargo_lifecycle_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    local -a argv=("$@")
    local sub="${argv[1]:-build}"
    _ensure_language_tool "$ir_file" "$line_num" "rustc"
    _ensure_language_tool "$ir_file" "$line_num" "cargo"
    case "$sub" in
        fetch)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_hook_block "$ir_file" "$line_num" "$((1600 + line_num * 10))" \
                'if [ -f Cargo.toml ]; then' \
                "  cargo fetch${extra:+ $extra}" \
                'fi'
            return 0
            ;;
        build|test|check|install)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "cargo $sub command preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1."
            _emit_hook_block "$ir_file" "$line_num" "$((1610 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f Cargo.toml ]; then' \
                "  cargo $sub${extra:+ $extra}" \
                'fi'
            return 0
            ;;
    esac
    return 1
}

_extract_go_lifecycle_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    local -a argv=("$@")
    local sub="${argv[1]:-}"
    _ensure_language_tool "$ir_file" "$line_num" "go"
    case "$sub" in
        mod)
            if [[ "${argv[2]:-}" == "download" ]]; then
                local extra
                extra=$(_join_from_index 3 "${argv[@]}")
                _emit_hook_block "$ir_file" "$line_num" "$((1700 + line_num * 10))" \
                    'if [ -f go.mod ]; then' \
                    "  go mod download${extra:+ $extra}" \
                    'fi'
                return 0
            fi
            ;;
        build|test|install|generate)
            local extra
            extra=$(_join_from_index 2 "${argv[@]}")
            _emit_language_review "$ir_file" "$line_num" "go $sub command preserved behind DOCK2FLOX_RUN_BUILD_STEPS=1."
            _emit_hook_block "$ir_file" "$line_num" "$((1710 + line_num * 10))" \
                'if [ "${DOCK2FLOX_RUN_BUILD_STEPS:-0}" = "1" ] && [ -f go.mod ]; then' \
                "  go $sub${extra:+ $extra}" \
                'fi'
            return 0
            ;;
    esac
    return 1
}

# --- Package-source and bounded-coverage review helpers ---

_review_package_source() {
    local ir_file="$1" line_num="$2" kind="$3" detail="$4"
    [[ -z "$detail" ]] && return 0
    ir_review "$ir_file" "package-source" "$kind source or external package input detected: $detail" "$line_num"
}

_token_is_external_package_artifact() {
    local token="$1"
    case "$token" in
        http://*.deb|https://*.deb|*.deb|./*.deb|../*.deb|/*.deb)
            return 0
            ;;
        http://*.rpm|https://*.rpm|*.rpm|./*.rpm|../*.rpm|/*.rpm)
            return 0
            ;;
        git+*|git@*|ssh://*|file://*)
            return 0
            ;;
    esac
    return 1
}

_detect_package_source_from_argv() {
    local ir_file="$1" line_num="$2"
    shift 2
    [[ $# -eq 0 ]] && return 1

    local -a argv=("$@")
    local cmd="${argv[0]}"
    local found=0
    local arg next_arg i

    case "$cmd" in
        add-apt-repository)
            _review_package_source "$ir_file" "$line_num" "apt" "${argv[*]}"
            return 0
            ;;
        apt-key)
            _review_package_source "$ir_file" "$line_num" "apt" "apt-key usage requires manual key/source review"
            return 0
            ;;
        gpg)
            for arg in "${argv[@]:1}"; do
                case "$arg" in
                    --dearmor|--recv-keys|--keyserver|--export|*.gpg|*.asc|*/keyrings/*)
                        _review_package_source "$ir_file" "$line_num" "gpg" "${argv[*]}"
                        return 0
                        ;;
                esac
            done
            ;;
        dpkg)
            if _argv_has_word "-i" "${argv[@]:1}" || _argv_has_word "--install" "${argv[@]:1}"; then
                _review_package_source "$ir_file" "$line_num" "deb" "${argv[*]}"
                return 0
            fi
            ;;
        rpm)
            for arg in "${argv[@]:1}"; do
                case "$arg" in
                    --import|-i|-U|-Uvh|-ivh|*.rpm|http://*.rpm|https://*.rpm)
                        _review_package_source "$ir_file" "$line_num" "rpm" "${argv[*]}"
                        return 0
                        ;;
                esac
            done
            ;;
        yum-config-manager)
            _review_package_source "$ir_file" "$line_num" "yum" "${argv[*]}"
            return 0
            ;;
        apt|apt-get|apk|yum|dnf)
            i=1
            while [[ "$i" -lt ${#argv[@]} ]]; do
                arg="${argv[$i]}"
                next_arg=""
                if [[ $((i + 1)) -lt ${#argv[@]} ]]; then
                    next_arg="${argv[$((i + 1))]}"
                fi
                case "$arg" in
                    update)
                        # update alone is expected after source configuration; not a review item.
                        ;;
                    --repository=*|-X*|--repo=*|--repofrompath=*|--setopt=*|--enablerepo=*|--disablerepo=*|--add-repo=*)
                        _review_package_source "$ir_file" "$line_num" "$cmd" "$arg"
                        found=1
                        ;;
                    --repository|-X|--repo|--repofrompath|--setopt|--enablerepo|--disablerepo|--add-repo)
                        _review_package_source "$ir_file" "$line_num" "$cmd" "$arg $next_arg"
                        found=1
                        i=$((i + 1))
                        ;;
                    config-manager)
                        if [[ "$next_arg" == "--add-repo" ]]; then
                            local repo_arg=""
                            if [[ $((i + 2)) -lt ${#argv[@]} ]]; then
                                repo_arg="${argv[$((i + 2))]}"
                            fi
                            _review_package_source "$ir_file" "$line_num" "$cmd" "config-manager --add-repo $repo_arg"
                            found=1
                            i=$((i + 2))
                        fi
                        ;;
                    --allow-untrusted|--nogpgcheck|--no-gpg-check)
                        _review_package_source "$ir_file" "$line_num" "$cmd" "$arg"
                        found=1
                        ;;
                    */sources.list|*/sources.list.d/*|ppa:*|deb[[:space:]]*)
                        _review_package_source "$ir_file" "$line_num" "$cmd" "$arg"
                        found=1
                        ;;
                    *)
                        if _token_is_external_package_artifact "$arg"; then
                            _review_package_source "$ir_file" "$line_num" "$cmd" "external package artifact: $arg"
                            found=1
                        fi
                        ;;
                esac
                i=$((i + 1))
            done
            ;;
        pip|pip3|uv)
            i=1
            while [[ "$i" -lt ${#argv[@]} ]]; do
                arg="${argv[$i]}"
                next_arg=""
                if [[ $((i + 1)) -lt ${#argv[@]} ]]; then
                    next_arg="${argv[$((i + 1))]}"
                fi
                case "$arg" in
                    --index-url|--extra-index-url|--find-links|--trusted-host)
                        _review_package_source "$ir_file" "$line_num" "pip" "$arg $next_arg"
                        found=1
                        i=$((i + 1))
                        ;;
                    --index-url=*|--extra-index-url=*|--find-links=*|--trusted-host=*)
                        _review_package_source "$ir_file" "$line_num" "pip" "$arg"
                        found=1
                        ;;
                    http://*|https://*|git+*|git@*|ssh://*|file://*)
                        _review_package_source "$ir_file" "$line_num" "pip" "$arg"
                        found=1
                        ;;
                esac
                i=$((i + 1))
            done
            ;;
        npm|npx|yarn|pnpm)
            i=1
            while [[ "$i" -lt ${#argv[@]} ]]; do
                arg="${argv[$i]}"
                next_arg=""
                if [[ $((i + 1)) -lt ${#argv[@]} ]]; then
                    next_arg="${argv[$((i + 1))]}"
                fi
                case "$arg" in
                    config|set)
                        if [[ " ${argv[*]} " == *" registry "* ]]; then
                            _review_package_source "$ir_file" "$line_num" "$cmd" "${argv[*]}"
                            found=1
                        fi
                        ;;
                    --registry|--npm-registry-server)
                        _review_package_source "$ir_file" "$line_num" "$cmd" "$arg $next_arg"
                        found=1
                        i=$((i + 1))
                        ;;
                    --registry=*|--npm-registry-server=*|http://*|https://*|git+*|git@*|ssh://*)
                        _review_package_source "$ir_file" "$line_num" "$cmd" "$arg"
                        found=1
                        ;;
                esac
                i=$((i + 1))
            done
            ;;
        curl|wget|tee|echo)
            for arg in "${argv[@]:1}"; do
                case "$arg" in
                    ppa:*|deb|deb-src|http://*|https://*|*.deb|*.rpm|*.gpg|*.asc|*/sources.list.d/*|*/keyrings/*|*/yum.repos.d/*|*/apk/repositories)
                        _review_package_source "$ir_file" "$line_num" "$cmd" "${argv[*]}"
                        found=1
                        break
                        ;;
                esac
                if [[ "$arg" == *"/etc/apt/"* || "$arg" == *"/etc/yum.repos.d/"* || "$arg" == *"/etc/apk/repositories"* ]]; then
                    _review_package_source "$ir_file" "$line_num" "$cmd" "${argv[*]}"
                    found=1
                    break
                fi
            done
            ;;
    esac

    [[ "$found" -eq 1 ]] && return 0
    return 1
}

_detect_package_source_in_command_text() {
    local cmd="$1" ir_file="$2" line_num="$3"
    local scratch
    scratch=$(dock2flox_mktemp)
    local -a words=()
    _shell_words_simple "$cmd" words
    [[ ${#words[@]} -eq 0 ]] && return 1
    if _detect_package_source_from_argv "$ir_file" "$line_num" "${words[@]}"; then
        return 0
    fi
    case "$cmd" in
        *'/etc/apt/sources.list'*|*'add-apt-repository'*|*'apt-key'*|*'/usr/share/keyrings/'*|*'.deb'*|*'/etc/apk/repositories'*|*'/etc/yum.repos.d/'*|*'.rpm'*|*'--index-url'*|*'--extra-index-url'*|*'--registry'*)
            _review_package_source "$ir_file" "$line_num" "package-source" "$cmd"
            return 0
            ;;
    esac
    return 1
}

# --- Known installer pattern detection ---

_detect_known_installer_from_argv() {
    local ir_file="$1" line_num="$2"
    shift 2

    local map_file="$DOCK2FLOX_DATA/known_installers.map"
    [[ ! -f "$map_file" ]] && return 1

    local found=0
    local arg pattern tool_name pkg_path
    for arg in "$@"; do
        [[ "$arg" == -* ]] && continue
        while IFS=$'\t' read -r pattern tool_name pkg_path; do
            [[ -z "$pattern" || "$pattern" == "#"* ]] && continue
            if [[ "$arg" == *"$pattern"* ]]; then
                log_verbose "Known installer detected: $tool_name (pattern: $pattern)"
                ir_install "$ir_file" "$tool_name" "$pkg_path" "" "" "EXACT" "$line_num" "detected installer script for $tool_name"
                found=1
            fi
        done < "$map_file"
    done

    [[ "$found" -eq 1 ]] && return 0
    return 1
}

_shell_words_simple() {
    local input="$1"
    local -n _out_words="$2"
    _out_words=()

    local i=0 len ch state="none" word=""
    len=${#input}

    while [[ "$i" -lt "$len" ]]; do
        ch="${input:$i:1}"

        case "$state" in
            single)
                if [[ "$ch" == "'" ]]; then
                    state="none"
                else
                    word+="$ch"
                fi
                i=$((i + 1))
                continue
                ;;
            double)
                if [[ "$ch" == "\\" ]]; then
                    if [[ $((i + 1)) -lt "$len" ]]; then
                        word+="${input:$((i + 1)):1}"
                        i=$((i + 2))
                    else
                        i=$((i + 1))
                    fi
                    continue
                fi
                if [[ "$ch" == '"' ]]; then
                    state="none"
                else
                    word+="$ch"
                fi
                i=$((i + 1))
                continue
                ;;
        esac

        case "$ch" in
            "'")
                state="single"
                ;;
            '"')
                state="double"
                ;;
            "\\")
                if [[ $((i + 1)) -lt "$len" ]]; then
                    word+="${input:$((i + 1)):1}"
                    i=$((i + 2))
                    continue
                fi
                ;;
            ' '|$'\t'|$'\n'|$'\r')
                if [[ -n "$word" ]]; then
                    _out_words+=("$word")
                    word=""
                fi
                ;;
            *)
                word+="$ch"
                ;;
        esac
        i=$((i + 1))
    done

    if [[ -n "$word" ]]; then
        _out_words+=("$word")
    fi
}

_detect_known_installer_in_command_text() {
    local cmd="$1" ir_file="$2" line_num="$3"
    local -a words=()
    _shell_words_simple "$cmd" words
    [[ ${#words[@]} -eq 0 ]] && return 1

    local i=0
    while [[ "$i" -lt ${#words[@]} ]]; do
        case "${words[$i]}" in
            if|then|else|elif|do|time)
                i=$((i + 1))
                ;;
            sudo|doas)
                i=$((i + 1))
                ;;
            env)
                i=$((i + 1))
                while [[ "$i" -lt ${#words[@]} ]]; do
                    case "${words[$i]}" in
                        -*|*=*) i=$((i + 1)) ;;
                        *) break ;;
                    esac
                done
                ;;
            *)
                break
                ;;
        esac
    done

    [[ "$i" -ge ${#words[@]} ]] && return 1
    local downloader="${words[$i]##*/}"
    [[ "$downloader" != "curl" && "$downloader" != "wget" ]] && return 1

    _detect_known_installer_from_argv "$ir_file" "$line_num" "${words[@]:$i}"
}

_matches_known_installer() {
    local cmd="$1"
    local scratch
    scratch=$(dock2flox_mktemp)
    _detect_known_installer_in_command_text "$cmd" "$scratch" "0"
}

_extract_corepack_enable() {
    local cmd="$1" ir_file="$2" line_num="$3"
    local map_file="$DOCK2FLOX_DATA/corepack_tools.map"

    [[ ! -f "$map_file" ]] && {
        ir_install "$ir_file" "corepack" "corepack" "" "" "EXACT" "$line_num" "from corepack enable"
        return 0
    }

    local args
    args=$(echo "$cmd" | sed -E 's/.*corepack[[:space:]]+enable[[:space:]]*//')
    args="${args//,/ }"

    local found=0
    local tool lookup_tool pkg_path notes
    for tool in $args; do
        [[ -z "$tool" ]] && continue
        [[ "$tool" == -* ]] && continue
        tool="${tool#\"}"
        tool="${tool%\"}"
        tool="${tool#'}"
        tool="${tool%'}"
        tool="${tool%%@*}"
        [[ -z "$tool" ]] && continue

        pkg_path=""
        notes=""
        while IFS=$'	' read -r lookup_tool pkg_path notes; do
            [[ -z "$lookup_tool" || "$lookup_tool" == "#"* ]] && continue
            if [[ "$lookup_tool" == "$tool" ]]; then
                break
            fi
            pkg_path=""
            notes=""
        done < "$map_file"

        if [[ -n "$pkg_path" ]]; then
            local install_id
            if [[ "$pkg_path" == *.* ]]; then
                install_id="${pkg_path##*.}"
            else
                install_id="$pkg_path"
            fi
            ir_install "$ir_file" "$install_id" "$pkg_path" "" "" "EXACT" "$line_num" "${notes:-from corepack enable $tool}"
            log_verbose "corepack: $tool -> $pkg_path (EXACT)"
            found=1
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        # `corepack enable` without a recognized tool requests the shim manager.
        ir_install "$ir_file" "corepack" "corepack" "" "" "EXACT" "$line_num" "from corepack enable"
    fi

    return 0
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


# --- OCI/runtime instruction helpers ---

_dockerfile_instruction_body() {
    local instruction="$1" line="$2"
    printf '%s' "$line" | sed -E "s/^${instruction}[[:space:]]+//I"
}

_oci_append_unique_word() {
    local current="$1" value="$2"
    [[ -z "$value" ]] && { printf '%s' "$current"; return 0; }

    local word
    for word in $current; do
        if [[ "$word" == "$value" ]]; then
            printf '%s' "$current"
            return 0
        fi
    done

    if [[ -z "$current" ]]; then
        printf '%s' "$value"
    else
        printf '%s %s' "$current" "$value"
    fi
}

_parse_workdir() {
    local line="$1" ir_file="$2" line_num="$3"
    local workdir
    workdir=$(_dockerfile_instruction_body "WORKDIR" "$line")
    workdir=$(_substitute_args "$workdir")
    workdir="${workdir#\"}"; workdir="${workdir%\"}"
    workdir="${workdir#\'}"; workdir="${workdir%\'}"
    [[ -z "$workdir" ]] && return 0

    oci_workdir="$workdir"
    ir_hook "$ir_file" "$((2200 + line_num))" "# Docker WORKDIR $workdir preserved; activation directory is mapped below when possible." "$line_num"
}

_parse_user() {
    local line="$1" ir_file="$2" line_num="$3"
    local user
    user=$(_dockerfile_instruction_body "USER" "$line")
    user=$(_substitute_args "$user")
    user="${user#\"}"; user="${user%\"}"
    user="${user#\'}"; user="${user%\'}"
    [[ -z "$user" ]] && return 0

    oci_user="$user"
    ir_hook "$ir_file" "$((2210 + line_num))" "# Docker USER $user preserved as metadata; Flox activation does not switch Unix users." "$line_num"
}

_parse_cmd() {
    local line="$1" ir_file="$2" line_num="$3"
    local body
    body=$(_dockerfile_instruction_body "CMD" "$line")
    body=$(_substitute_args "$body")
    oci_cmd=$(_docker_instruction_command_to_shell "$body")
    if [[ -n "$oci_cmd" ]]; then
        ir_hook "$ir_file" "$((2220 + line_num))" "# Docker CMD preserved for generated app service: $oci_cmd" "$line_num"
    fi
}

_parse_entrypoint() {
    local line="$1" ir_file="$2" line_num="$3"
    local body
    body=$(_dockerfile_instruction_body "ENTRYPOINT" "$line")
    body=$(_substitute_args "$body")
    oci_entrypoint=$(_docker_instruction_command_to_shell "$body")
    if [[ -n "$oci_entrypoint" ]]; then
        ir_hook "$ir_file" "$((2230 + line_num))" "# Docker ENTRYPOINT preserved for generated app service: $oci_entrypoint" "$line_num"
    fi
}

_parse_copy_add() {
    local instruction="$1" line="$2" ir_file="$3" line_num="$4"
    local body
    body=$(_dockerfile_instruction_body "$instruction" "$line")
    body=$(_substitute_args "$body")
    [[ -z "$body" ]] && return 0

    local note="# Docker $instruction $body preserved as filesystem/build context metadata."
    if [[ "$body" == *"--from="* ]]; then
        note+=" Review: build-stage artifacts must be rebuilt or supplied outside Flox."
    fi
    if [[ "$body" == *"--chown="* || "$body" == *"--chmod="* ]]; then
        note+=" Review: ownership/mode flags do not directly map to Flox activation."
    fi
    if [[ "$instruction" == "ADD" && "$body" =~ https?:// ]]; then
        note+=" Review: remote ADD should usually become an explicit fetch/checksum step."
    fi

    ir_hook "$ir_file" "$((2240 + line_num))" "$note" "$line_num"
}

_parse_healthcheck() {
    local line="$1" ir_file="$2" line_num="$3"
    local body
    body=$(_dockerfile_instruction_body "HEALTHCHECK" "$line")
    body=$(_substitute_args "$body")
    [[ -z "$body" ]] && return 0

    oci_healthcheck="$body"
    ir_hook "$ir_file" "$((2250 + line_num))" "# Docker HEALTHCHECK preserved as metadata; wire this into your process supervisor or deploy target if needed." "$line_num"
}

_parse_stopsignal() {
    local line="$1" ir_file="$2" line_num="$3"
    local body
    body=$(_dockerfile_instruction_body "STOPSIGNAL" "$line")
    body=$(_substitute_args "$body")
    [[ -z "$body" ]] && return 0

    oci_stopsignal="$body"
    ir_hook "$ir_file" "$((2260 + line_num))" "# Docker STOPSIGNAL $body preserved as metadata; Flox services use the host supervisor signal model." "$line_num"
}

_parse_shell() {
    local line="$1" ir_file="$2" line_num="$3"
    local body
    body=$(_dockerfile_instruction_body "SHELL" "$line")
    body=$(_substitute_args "$body")
    [[ -z "$body" ]] && return 0

    oci_shell=$(_docker_instruction_command_to_shell "$body")
    [[ -z "$oci_shell" ]] && oci_shell="$body"
    current_shell_kind=$(_infer_docker_shell_kind "$body")
    current_shell_explicit=1
    current_shell_desc="$oci_shell"
    ir_hook "$ir_file" "$((2270 + line_num))" "# Docker SHELL $body preserved as metadata; RUN analysis honors this shell for active extraction." "$line_num"
}

_infer_docker_shell_kind() {
    local body="$1" words first base
    words=$(_docker_instruction_array_or_shell_to_words "$body")
    first=$(printf '%s\n' "$words" | awk '{print $1}')
    base="${first##*/}"
    case "$base" in
        bash) printf 'bash' ;;
        sh|dash|ash|busybox) printf 'sh' ;;
        cmd|cmd.exe|powershell|powershell.exe|pwsh|pwsh.exe) printf 'unsupported' ;;
        "") printf 'unknown' ;;
        *) printf 'unknown' ;;
    esac
}

_parse_label() {
    local line="$1" ir_file="$2" line_num="$3"
    local body
    body=$(_dockerfile_instruction_body "LABEL" "$line")
    body=$(_substitute_args "$body")
    [[ -z "$body" ]] && return 0

    ir_hook "$ir_file" "$((2280 + line_num))" "# Docker LABEL preserved as metadata: $body" "$line_num"
}

_parse_volume() {
    local line="$1" ir_file="$2" line_num="$3"
    local body
    body=$(_dockerfile_instruction_body "VOLUME" "$line")
    body=$(_substitute_args "$body")
    [[ -z "$body" ]] && return 0

    local volume_text
    volume_text=$(_docker_instruction_array_or_shell_to_words "$body")
    [[ -z "$volume_text" ]] && volume_text="$body"
    local vol
    for vol in $volume_text; do
        oci_volumes=$(_oci_append_unique_word "${oci_volumes:-}" "$vol")
    done
    ir_hook "$ir_file" "$((2290 + line_num))" "# Docker VOLUME $body preserved as metadata; map persistent data to FLOX_ENV_CACHE or an external volume explicitly." "$line_num"
}

_docker_instruction_command_to_shell() {
    local body="$1"
    body="${body#${body%%[![:space:]]*}}"
    body="${body%${body##*[![:space:]]}}"
    [[ -z "$body" ]] && return 0

    if [[ "$body" == \[*\] ]]; then
        _docker_json_array_to_shell "$body"
    else
        printf '%s' "$body"
    fi
}

_docker_instruction_array_or_shell_to_words() {
    local body="$1"
    body="${body#${body%%[![:space:]]*}}"
    body="${body%${body##*[![:space:]]}}"
    [[ -z "$body" ]] && return 0

    if [[ "$body" == \[*\] ]]; then
        _docker_json_array_to_plain_words "$body"
    else
        printf '%s' "$body"
    fi
}

_docker_json_array_to_shell() {
    local json="$1" out
    # Fast path for the simple JSON arrays Dockerfiles use most often. Python
    # startup is expensive in minimal CI/sandbox environments, so use the shell
    # fallback first and reserve Python for arrays the fallback cannot parse.
    out=$(_docker_json_array_fallback "$json" "shell")
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$json" <<'PYJSON' 2>/dev/null && return 0
import json, shlex, sys
try:
    value = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if not isinstance(value, list):
    raise SystemExit(1)
print(" ".join(shlex.quote(str(item)) for item in value))
PYJSON
    fi
}

_docker_json_array_to_plain_words() {
    local json="$1" out
    out=$(_docker_json_array_fallback "$json" "plain")
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$json" <<'PYJSON' 2>/dev/null && return 0
import json, sys
try:
    value = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if not isinstance(value, list):
    raise SystemExit(1)
print(" ".join(str(item) for item in value))
PYJSON
    fi
}

_docker_json_array_fallback() {
    local json="$1" mode="${2:-shell}"
    local inner item out=""
    inner="${json#[}"
    inner="${inner%]}"
    inner="${inner//\",\"/$'\n'}"
    inner="${inner//\", \"/$'\n'}"
    inner="${inner//\'/}"
    inner="${inner//\"/}"
    while IFS= read -r item; do
        item="${item#${item%%[![:space:]]*}}"
        item="${item%${item##*[![:space:]]}}"
        [[ -z "$item" ]] && continue
        if [[ "$mode" == "shell" ]]; then
            item=$(printf '%q' "$item")
        fi
        if [[ -z "$out" ]]; then
            out="$item"
        else
            out+=" $item"
        fi
    done <<< "$inner"
    printf '%s' "$out"
}

_emit_oci_final_records() {
    local ir_file="$1" line_num="${2:-0}"

    if [[ -n "${oci_workdir:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_CONTAINER_WORKDIR" "$oci_workdir" "$line_num"
        case "$oci_workdir" in
            /|/app|/app/*|/usr/src/app|/usr/src/app/*|/workspace|/workspace/*|/workspaces/*|/code|/code/*|/src|/src/*)
                ir_hook "$ir_file" "060" 'export DOCK2FLOX_ACTIVATE_DIR="$FLOX_ENV_PROJECT"' "$line_num"
                ;;
            /*)
                ir_hook "$ir_file" "060" "# Docker WORKDIR $oci_workdir is absolute inside the image; review whether it should map to FLOX_ENV_PROJECT or FLOX_ENV_CACHE." "$line_num"
                ;;
            *)
                local rel="$oci_workdir"
                rel="${rel#./}"
                ir_hook "$ir_file" "060" "export DOCK2FLOX_ACTIVATE_DIR=\"\$FLOX_ENV_PROJECT/$rel\"" "$line_num"
                ir_hook "$ir_file" "061" 'mkdir -p "$DOCK2FLOX_ACTIVATE_DIR"' "$line_num"
                ;;
        esac
    fi

    if [[ -n "${oci_user:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_CONTAINER_USER" "$oci_user" "$line_num"
    fi

    if [[ -n "${oci_exposed_ports:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_EXPOSED_PORTS" "$oci_exposed_ports" "$line_num"
    fi

    if [[ -n "${oci_volumes:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_CONTAINER_VOLUMES" "$oci_volumes" "$line_num"
    fi

    if [[ -n "${oci_healthcheck:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_HEALTHCHECK" "$oci_healthcheck" "$line_num"
    fi

    if [[ -n "${oci_stopsignal:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_STOPSIGNAL" "$oci_stopsignal" "$line_num"
    fi

    if [[ -n "${oci_shell:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_CONTAINER_SHELL" "$oci_shell" "$line_num"
    fi

    if [[ -n "${oci_entrypoint:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_CONTAINER_ENTRYPOINT" "$oci_entrypoint" "$line_num"
    fi

    if [[ -n "${oci_cmd:-}" ]]; then
        ir_var "$ir_file" "DOCK2FLOX_CONTAINER_CMD" "$oci_cmd" "$line_num"
    fi

    local runtime_cmd
    runtime_cmd=$(_combine_oci_entrypoint_cmd "${oci_entrypoint:-}" "${oci_cmd:-}")
    if [[ -n "$runtime_cmd" ]]; then
        local service_cmd
        service_cmd="# Derived from Dockerfile ENTRYPOINT/CMD. Review filesystem, user, port, and volume assumptions before treating this as production-equivalent."
        if [[ -n "${oci_user:-}" ]]; then
            service_cmd+=$'\n'"# Original Docker USER: $oci_user"
        fi
        if [[ -n "${oci_workdir:-}" ]]; then
            service_cmd+=$'\n''cd "${DOCK2FLOX_ACTIVATE_DIR:-$FLOX_ENV_PROJECT}"'
        fi
        service_cmd+=$'\n'"$runtime_cmd"
        ir_service "$ir_file" "app" "$service_cmd" "$line_num"
    fi
}

_combine_oci_entrypoint_cmd() {
    local entrypoint="$1" cmd="$2"
    if [[ -n "$entrypoint" && -n "$cmd" ]]; then
        printf '%s %s' "$entrypoint" "$cmd"
    elif [[ -n "$entrypoint" ]]; then
        printf '%s' "$entrypoint"
    else
        printf '%s' "$cmd"
    fi
}

_parse_expose() {
    local line="$1" ir_file="$2" line_num="$3"
    local ports
    ports=$(_dockerfile_instruction_body "EXPOSE" "$line")
    ports=$(_substitute_args "$ports")
    [[ -z "$ports" ]] && return 0

    local port
    for port in $ports; do
        port="${port%%/*}" # strip /tcp, /udp
        port="${port#\"}"; port="${port%\"}"
        port="${port#\'}"; port="${port%\'}"
        [[ -z "$port" ]] && continue
        oci_exposed_ports=$(_oci_append_unique_word "${oci_exposed_ports:-}" "$port")
        log_verbose "Noted exposed port: $port (line $line_num)"
    done

    ir_hook "$ir_file" "$((2300 + line_num))" "# Docker EXPOSE $ports preserved as metadata; Flox does not publish ports automatically." "$line_num"
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
