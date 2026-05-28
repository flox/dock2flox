#!/usr/bin/env bash
# dock2flox RUN shell interpreter
#
# Uses Bash itself to parse Dockerfile RUN bodies, expand shell variables, and
# walk control-flow constructs. Installer and package-manager commands are
# stubbed so the analyzer records argv without installing or downloading
# anything. Potentially write-capable shell constructs are rejected before
# interpretation so the analyzer never writes through Bash redirections.

# Requires: lib/core.sh sourced first

_run_body_has_unsafe_shell_effects() {
    local body="$1"
    local i=0 len ch state="none"
    len=${#body}

    while [[ "$i" -lt "$len" ]]; do
        ch="${body:$i:1}"

        case "$state" in
            single)
                if [[ "$ch" == "'" ]]; then
                    state="none"
                fi
                i=$((i + 1))
                continue
                ;;
            double)
                if [[ "$ch" == "\\" ]]; then
                    i=$((i + 2))
                    continue
                fi
                if [[ "$ch" == '"' ]]; then
                    state="none"
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
                i=$((i + 2))
                continue
                ;;
            '>'|'<')
                return 0
                ;;
        esac
        i=$((i + 1))
    done

    return 1
}

_run_body_has_unmodelled_keyword_tests() {
    local body="$1"
    # Bash [[ ... ]] is syntax, not a command, so the interpreter cannot stub
    # file predicates inside it. Fall back when it contains file-test operators.
    if [[ "$body" == *"[["* ]]; then
        case "$body" in
            *" -e "*|*" -f "*|*" -d "*|*" -x "*|*" -s "*)
                return 0
                ;;
        esac
    fi
    return 1
}

_normalize_modelled_keyword_tests() {
    local body="$1"
    # Bash [[ ... ]] is syntax and cannot be replaced with a function. Normalize
    # only exact common distro file probes into `test`, which the interpreter
    # stubs using the inferred base-image package manager.
    sed \
        -e 's/\[\[[[:space:]]*-f[[:space:]]*\/etc\/alpine-release[[:space:]]*\]\]/test -f \/etc\/alpine-release/g' \
        -e 's/\[\[[[:space:]]*-e[[:space:]]*\/etc\/alpine-release[[:space:]]*\]\]/test -e \/etc\/alpine-release/g' \
        -e 's/\[\[[[:space:]]*-f[[:space:]]*\/etc\/debian_version[[:space:]]*\]\]/test -f \/etc\/debian_version/g' \
        -e 's/\[\[[[:space:]]*-e[[:space:]]*\/etc\/debian_version[[:space:]]*\]\]/test -e \/etc\/debian_version/g' \
        -e 's/\[\[[[:space:]]*-f[[:space:]]*\/etc\/apt\/sources.list[[:space:]]*\]\]/test -f \/etc\/apt\/sources.list/g' \
        -e 's/\[\[[[:space:]]*-e[[:space:]]*\/etc\/apt\/sources.list[[:space:]]*\]\]/test -e \/etc\/apt\/sources.list/g' \
        -e 's/\[\[[[:space:]]*-f[[:space:]]*\/etc\/yum.conf[[:space:]]*\]\]/test -f \/etc\/yum.conf/g' \
        -e 's/\[\[[[:space:]]*-e[[:space:]]*\/etc\/yum.conf[[:space:]]*\]\]/test -e \/etc\/yum.conf/g' \
        -e 's/\[\[[[:space:]]*-f[[:space:]]*\/etc\/dnf\/dnf.conf[[:space:]]*\]\]/test -f \/etc\/dnf\/dnf.conf/g' \
        -e 's/\[\[[[:space:]]*-e[[:space:]]*\/etc\/dnf\/dnf.conf[[:space:]]*\]\]/test -e \/etc\/dnf\/dnf.conf/g' \
        <<< "$body"
}


interpret_run_body() {
    local run_body="$1"
    local events_file="$2"
    local pkg_manager="${3:-unknown}"
    local machine_arch="${4:-x86_64}"
    local shell_kind="${5:-bash}"
    local env_file="${6:-}"

    : > "$events_file"
    run_body=$(_normalize_modelled_keyword_tests "$run_body")

    if _run_body_has_unsafe_shell_effects "$run_body"; then
        printf 'UNCERTAIN	%s
' "redirection/process-substitution in RUN body" >> "$events_file"
        log_verbose "RUN shell interpretation skipped: redirection or process-substitution syntax present"
        return 0
    fi

    if _run_body_has_unmodelled_keyword_tests "$run_body"; then
        printf 'UNCERTAIN	%s
' "unmodelled [[ file-test ]] predicate" >> "$events_file"
        log_verbose "RUN shell interpretation skipped: unmodelled [[ file-test ]] predicate present"
        return 0
    fi

    local script_file run_dir
    script_file=$(dock2flox_mktemp)
    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/dock2flox.run.XXXXXX")

    cat > "$script_file" <<'BASH_INNER'
#!/usr/bin/env bash
set +e
set +u
set +o pipefail 2>/dev/null || true
set -f

# Prevent external command lookup. Known commands below are shell functions;
# unknown commands are captured by command_not_found_handle.
PATH=/nonexistent
export PATH

__d2f_events_file="${DOCK2FLOX_RUN_EVENTS:-}"
__d2f_pkg_manager="${DOCK2FLOX_RUN_PKG_MANAGER:-unknown}"
__d2f_env_file="${DOCK2FLOX_RUN_ENV_FILE:-}"

if [[ -n "$__d2f_env_file" && -f "$__d2f_env_file" ]]; then
    # The parent parser writes this file as sanitized `export NAME=<quoted>`
    # assignments, one per Dockerfile ENV visible to this RUN.
    # shellcheck source=/dev/null
    source "$__d2f_env_file"
fi

__d2f_encode() {
    local value="${1-}"
    value="${value//\\/\\\\}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    printf '%s' "$value"
}

__d2f_emit_record() {
    [[ -z "$__d2f_events_file" ]] && return 0
    local kind="$1"
    shift
    local arg record
    record="$kind"
    for arg in "$@"; do
        record+=$'\t'
        record+="$(__d2f_encode "$arg")"
    done
    printf '%s\n' "$record" >> "$__d2f_events_file"
    return 0
}

__d2f_emit() { __d2f_emit_record CMD "$@"; return 0; }
__d2f_uncertain() { __d2f_emit_record UNCERTAIN "$@"; return 0; }

# Package managers and language installers that dock2flox knows how to map.
apt-get() { __d2f_emit apt-get "$@"; return 0; }
apt() { __d2f_emit apt "$@"; return 0; }
apk() { __d2f_emit apk "$@"; return 0; }
yum() { __d2f_emit yum "$@"; return 0; }
dnf() { __d2f_emit dnf "$@"; return 0; }
add-apt-repository() { __d2f_emit add-apt-repository "$@"; return 0; }
apt-key() { __d2f_emit apt-key "$@"; return 0; }
dpkg() { __d2f_emit dpkg "$@"; return 0; }
gpg() { __d2f_emit gpg "$@"; return 0; }
yum-config-manager() { __d2f_emit yum-config-manager "$@"; return 0; }
rpm() { __d2f_emit rpm "$@"; return 0; }
tee() { __d2f_emit tee "$@"; while IFS= read -r _line; do :; done; return 0; }
echo() { __d2f_emit echo "$@"; builtin echo "$@"; return 0; }
pip() { __d2f_emit pip "$@"; return 0; }
pip3() { __d2f_emit pip3 "$@"; return 0; }
uv() { __d2f_emit uv "$@"; return 0; }
npm() { __d2f_emit npm "$@"; return 0; }
npx() { __d2f_emit npx "$@"; return 0; }
corepack() { __d2f_emit corepack "$@"; return 0; }
mkdir() { __d2f_emit mkdir "$@"; return 0; }
python() { __d2f_emit python "$@"; return 0; }
python3() { __d2f_emit python3 "$@"; return 0; }
virtualenv() { __d2f_emit virtualenv "$@"; return 0; }
poetry() { __d2f_emit poetry "$@"; return 0; }
pdm() { __d2f_emit pdm "$@"; return 0; }
pipenv() { __d2f_emit pipenv "$@"; return 0; }
node() { __d2f_emit node "$@"; return 0; }
pnpm() { __d2f_emit pnpm "$@"; return 0; }
yarn() { __d2f_emit yarn "$@"; return 0; }
ruby() { __d2f_emit ruby "$@"; return 0; }
bundle() { __d2f_emit bundle "$@"; return 0; }
bundler() { __d2f_emit bundler "$@"; return 0; }
gem() { __d2f_emit gem "$@"; return 0; }
php() { __d2f_emit php "$@"; return 0; }
cargo() { __d2f_emit cargo "$@"; return 0; }
rustup() { __d2f_emit rustup "$@"; return 0; }
go() { __d2f_emit go "$@"; return 0; }
composer() { __d2f_emit composer "$@"; return 0; }
java() { __d2f_emit java "$@"; return 0; }
mvn() { __d2f_emit mvn "$@"; return 0; }
gradle() { __d2f_emit gradle "$@"; return 0; }
./mvnw() { __d2f_emit ./mvnw "$@"; return 0; }
./gradlew() { __d2f_emit ./gradlew "$@"; return 0; }
make() { __d2f_emit make "$@"; return 0; }
cmake() { __d2f_emit cmake "$@"; return 0; }

# File operations — no-ops in interpreter (common Dockerfile cleanup/setup)
rm() { return 0; }
cp() { return 0; }
mv() { return 0; }
ln() { return 0; }
touch() { return 0; }
chmod() { return 0; }
chown() { return 0; }
chgrp() { return 0; }
install() { return 0; }
tar() { return 0; }
unzip() { return 0; }
gzip() { return 0; }
gunzip() { return 0; }
xz() { return 0; }
bzip2() { return 0; }
bunzip2() { return 0; }

# Text utilities — no-ops (output consumed by pipes, not meaningful for extraction)
cat() { return 0; }
sed() { return 0; }
awk() { return 0; }
grep() { return 0; }
egrep() { return 0; }
fgrep() { return 0; }
head() { return 0; }
tail() { return 0; }
wc() { builtin echo "0"; return 0; }
sort() { return 0; }
cut() { return 0; }
tr() { return 0; }
yes() { return 0; }
find() { return 0; }
file() { return 0; }
stat() { return 0; }
readlink() { return 0; }
realpath() { return 0; }
basename() { builtin echo "${1##*/}"; return 0; }
dirname() { builtin echo "${1%/*}"; return 0; }
which() { return 0; }
ls() { return 0; }
pwd() { builtin echo "/workspace"; return 0; }
rmdir() { return 0; }
mktemp() { builtin echo "/tmp/dock2flox-tmp.XXXXXX"; return 0; }
# NOTE: Do NOT override printf or read — they are used by internal __d2f_* functions

# Checksums — no-ops
sha256sum() { return 0; }
sha512sum() { return 0; }
md5sum() { return 0; }
sha1sum() { return 0; }

# User management — no-ops (OCI-specific)
groupadd() { return 0; }
useradd() { return 0; }
adduser() { return 0; }
addgroup() { return 0; }
usermod() { return 0; }

# System config — no-ops (OCI-specific)
ldconfig() { return 0; }
update-ca-certificates() { return 0; }
locale-gen() { return 0; }
update-alternatives() { return 0; }
dpkg-reconfigure() { return 0; }
sync() { return 0; }
sleep() { return 0; }
date() { builtin echo "2026-01-01T00:00:00Z"; return 0; }

# Deterministic models for common probes used in architecture/OS branches.
# These print to stdout because callers often use command substitution.
uname() {
    case "${1-}" in
        -m|--machine) printf '%s\n' "${DOCK2FLOX_RUN_ARCH:-x86_64}" ;;
        -s|--kernel-name) printf 'Linux\n' ;;
        -a|--all) printf 'Linux dock2flox 0.0.0 %s GNU/Linux\n' "${DOCK2FLOX_RUN_ARCH:-x86_64}" ;;
        *) printf 'Linux\n' ;;
    esac
    return 0
}

id() {
    case "${1-}" in
        -u) printf '0\n' ;;
        -g) printf '0\n' ;;
        -un) printf 'root\n' ;;
        -gn) printf 'root\n' ;;
        *) printf 'uid=0(root) gid=0(root) groups=0(root)\n' ;;
    esac
    return 0
}

whoami() { printf 'root\n'; return 0; }

# Downloaders are recorded for known-installer URL detection, but they produce
# no stdout so curl|bash style installers do not execute fetched content.
curl() { __d2f_emit curl "$@"; return 0; }
wget() { __d2f_emit wget "$@"; return 0; }

# Wrapper dispatch must never execute arbitrary analyzer-host commands. Bash
# functions above are safe stubs that only emit events; any unmodelled command,
# slash-addressed command, or command-position variable expansion is review-only.
__d2f_is_modeled_invocable() {
    local name="${1-}"
    case "$name" in
        # Package managers
        apt-get|apt|apk|yum|dnf|add-apt-repository|apt-key|dpkg|gpg|yum-config-manager|rpm)
            return 0 ;;
        # Language tools
        pip|pip3|uv|npm|npx|corepack|python|python3|virtualenv|poetry|pdm|pipenv|node|pnpm|yarn)
            return 0 ;;
        ruby|bundle|bundler|gem|php|cargo|rustup|go|composer|java|mvn|gradle|./mvnw|./gradlew|make|cmake)
            return 0 ;;
        # Downloaders / interpreters
        curl|wget|sh|bash)
            return 0 ;;
        # System probes
        uname|id|whoami|command|test|'[')
            return 0 ;;
        # File operations
        rm|cp|mv|ln|touch|chmod|chown|chgrp|install|mkdir|rmdir|mktemp)
            return 0 ;;
        tar|unzip|gzip|gunzip|xz|bzip2|bunzip2)
            return 0 ;;
        # Text utilities
        cat|sed|awk|grep|egrep|fgrep|head|tail|wc|sort|cut|tr|tee|echo|printf|yes|find)
            return 0 ;;
        # File info
        ls|pwd|basename|dirname|which|file|stat|readlink|realpath)
            return 0 ;;
        # Checksums
        sha256sum|sha512sum|md5sum|sha1sum)
            return 0 ;;
        # User management
        groupadd|useradd|adduser|addgroup|usermod)
            return 0 ;;
        # System config
        ldconfig|update-ca-certificates|locale-gen|update-alternatives|dpkg-reconfigure|sync|sleep|date)
            return 0 ;;
        # Wrappers
        sudo|doas|env|xargs|builtin)
            return 0 ;;
        # Shell builtins
        true|false|:|set|shopt|export|unset|declare|readonly|local|read|exec|shift|break|continue|return|cd|pushd|popd)
            return 0 ;;
        '')
            return 1 ;;
    esac
    return 1
}

__d2f_safe_invoke() {
    [[ $# -eq 0 ]] && return 0
    local name="${1-}"
    case "$name" in
        ./mvnw|./gradlew)
            : ;;
        */*)
            __d2f_uncertain "unsafe path-addressed command not executed: $name"
            return 0 ;;
    esac
    if __d2f_is_modeled_invocable "$name"; then
        "$@"
    else
        __d2f_uncertain "unmodelled wrapper command not executed: $name"
    fi
    return 0
}

sudo() {
    __d2f_emit sudo "$@"
    __d2f_safe_invoke "$@"
    return 0
}

doas() {
    __d2f_emit doas "$@"
    __d2f_safe_invoke "$@"
    return 0
}

env() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--ignore-environment)
                shift
                ;;
            -*=*)
                shift
                ;;
            -* )
                shift
                ;;
            *=*)
                export "$1"
                shift
                ;;
            *)
                break
                ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        __d2f_safe_invoke "$@"
    else
        __d2f_emit env
    fi
    return 0
}

__d2f_command_available() {
    local name="${1-}"
    case "$name" in
        command|builtin|test|'['|']'|true|false|:|set|export|unset|shift|case|if|then|else|fi|for|do|done|while|until|break|continue|return)
            return 0
            ;;
        sh|bash|env|sudo|doas|xargs)
            return 0
            ;;
        node|npm|npx|corepack|yarn|pnpm|ruby|bundle|bundler|gem|php|composer|java|mvn|gradle|cargo|rustup|go|make|cmake)
            return 0
            ;;
        apt|apt-get)
            case "$__d2f_pkg_manager" in
                apt) return 0 ;;
                apk|yum|dnf) return 1 ;;
            esac
            __d2f_uncertain "command -v $name"
            return 1
            ;;
        apk)
            case "$__d2f_pkg_manager" in
                apk) return 0 ;;
                apt|yum|dnf) return 1 ;;
            esac
            __d2f_uncertain "command -v $name"
            return 1
            ;;
        yum)
            case "$__d2f_pkg_manager" in
                yum) return 0 ;;
                apt|apk|dnf) return 1 ;;
            esac
            __d2f_uncertain "command -v $name"
            return 1
            ;;
        dnf)
            case "$__d2f_pkg_manager" in
                dnf) return 0 ;;
                apt|apk|yum) return 1 ;;
            esac
            __d2f_uncertain "command -v $name"
            return 1
            ;;
        '')
            return 1
            ;;
    esac

    __d2f_uncertain "command -v $name"
    return 1
}

command() {
    if [[ "${1-}" == "-v" || "${1-}" == "-V" ]]; then
        __d2f_command_available "${2-}"
        return $?
    fi
    # POSIX `command foo ...` bypasses shell functions in a real shell. In the
    # analyzer, bypassing stubs would be unsafe, so dispatch only to modeled
    # stub functions and otherwise emit uncertainty.
    __d2f_emit command "$@"
    __d2f_safe_invoke "$@"
    return 0
}

builtin() {
    if [[ "${1-}" == "command" ]]; then
        shift
        command "$@"
        return 0
    fi
    __d2f_emit builtin "$@"
    return 0
}

__d2f_known_file_test() {
    local op="${1-}" path="${2-}"
    case "$path" in
        /etc/alpine-release)
            [[ "$__d2f_pkg_manager" == "apk" ]] && return 0
            return 1
            ;;
        /etc/debian_version|/etc/apt/sources.list)
            [[ "$__d2f_pkg_manager" == "apt" ]] && return 0
            return 1
            ;;
        /etc/yum.conf)
            [[ "$__d2f_pkg_manager" == "yum" ]] && return 0
            return 1
            ;;
        /etc/dnf/dnf.conf)
            [[ "$__d2f_pkg_manager" == "dnf" ]] && return 0
            return 1
            ;;
        /etc/os-release)
            case "$__d2f_pkg_manager" in
                apt|apk|yum|dnf) return 0 ;;
            esac
            ;;
    esac
    __d2f_uncertain "$op $path"
    return 1
}

__d2f_test() {
    local -a args=("$@")
    local count=${#args[@]}
    if [[ "$count" -gt 0 && "${args[$((count - 1))]}" == "]" ]]; then
        unset 'args[$((count - 1))]'
        count=${#args[@]}
    fi

    if [[ "$count" -eq 0 ]]; then
        return 1
    fi

    if [[ "$count" -eq 1 ]]; then
        [[ -n "${args[0]}" ]] && return 0
        return 1
    fi

    if [[ "$count" -eq 2 ]]; then
        case "${args[0]}" in
            -e|-f|-d|-x|-s)
                __d2f_known_file_test "${args[0]}" "${args[1]}"
                return $?
                ;;
            -n)
                [[ -n "${args[1]}" ]] && return 0
                return 1
                ;;
            -z)
                [[ -z "${args[1]}" ]] && return 0
                return 1
                ;;
        esac
    fi

    if [[ "$count" -eq 3 ]]; then
        case "${args[1]}" in
            =|==)
                [[ "${args[0]}" == "${args[2]}" ]] && return 0
                return 1
                ;;
            '!=')
                [[ "${args[0]}" != "${args[2]}" ]] && return 0
                return 1
                ;;
            -eq)
                [[ "${args[0]}" -eq "${args[2]}" ]] 2>/dev/null && return 0
                return 1
                ;;
            -ne)
                [[ "${args[0]}" -ne "${args[2]}" ]] 2>/dev/null && return 0
                return 1
                ;;
            -lt)
                [[ "${args[0]}" -lt "${args[2]}" ]] 2>/dev/null && return 0
                return 1
                ;;
            -le)
                [[ "${args[0]}" -le "${args[2]}" ]] 2>/dev/null && return 0
                return 1
                ;;
            -gt)
                [[ "${args[0]}" -gt "${args[2]}" ]] 2>/dev/null && return 0
                return 1
                ;;
            -ge)
                [[ "${args[0]}" -ge "${args[2]}" ]] 2>/dev/null && return 0
                return 1
                ;;
        esac
    fi

    __d2f_uncertain "test ${args[*]}"
    return 1
}

test() { __d2f_test "$@"; return $?; }
[() { __d2f_test "$@"; return $?; }

xargs() {
    __d2f_emit xargs "$@"
    local -a argv=("$@")
    local i=0
    while [[ $i -lt ${#argv[@]} ]]; do
        case "${argv[$i]}" in
            -0|-r|--no-run-if-empty)
                i=$((i + 1))
                ;;
            -n|-P|-I|--max-args|--max-procs|--replace)
                i=$((i + 2))
                ;;
            *)
                break
                ;;
        esac
    done
    if [[ $i -lt ${#argv[@]} ]]; then
        __d2f_safe_invoke "${argv[@]:$i}"
    fi
    return 0
}

sh() {
    if [[ "${1-}" == "-c" ]]; then
        __d2f_emit sh "$@"
        __d2f_uncertain "shell -c wrapper not executed by analyzer: sh -c"
    else
        __d2f_emit sh "$@"
        while IFS= read -r _line; do :; done
    fi
    return 0
}

bash() {
    if [[ "${1-}" == "-c" ]]; then
        __d2f_emit bash "$@"
        __d2f_uncertain "shell -c wrapper not executed by analyzer: bash -c"
    else
        __d2f_emit bash "$@"
        while IFS= read -r _line; do :; done
    fi
    return 0
}

source() { __d2f_emit source "$@"; return 0; }
.() { __d2f_emit . "$@"; return 0; }
eval() { __d2f_emit eval "$@"; return 0; }
exec() { __d2f_emit exec "$@"; return 0; }
trap() { return 0; }
alias() { return 0; }
unalias() { return 0; }
enable() { return 0; }
hash() { return 0; }

command_not_found_handle() {
    __d2f_emit "$@"
    return 0
}

BASH_INNER

    printf '\n# --- Dockerfile RUN body interpreted by dock2flox ---\n' >> "$script_file"
    printf '%s\n' "$run_body" >> "$script_file"

    local status=0
    local run_timeout="${DOCK2FLOX_RUN_TIMEOUT:-5s}"
    case "$run_timeout" in
        ''|*[!0-9smh.]*)
            run_timeout="5s"
            ;;
    esac

    if command -v timeout >/dev/null 2>&1; then
        ( cd "$run_dir" && DOCK2FLOX_RUN_EVENTS="$events_file" DOCK2FLOX_RUN_PKG_MANAGER="$pkg_manager" DOCK2FLOX_RUN_ARCH="$machine_arch" DOCK2FLOX_RUN_SHELL_KIND="$shell_kind" DOCK2FLOX_RUN_ENV_FILE="$env_file" timeout --kill-after=1s "$run_timeout" bash --noprofile --norc "$script_file" >/dev/null 2>&1 ) || status=$?
    else
        ( cd "$run_dir" && DOCK2FLOX_RUN_EVENTS="$events_file" DOCK2FLOX_RUN_PKG_MANAGER="$pkg_manager" DOCK2FLOX_RUN_ARCH="$machine_arch" DOCK2FLOX_RUN_SHELL_KIND="$shell_kind" DOCK2FLOX_RUN_ENV_FILE="$env_file" bash --noprofile --norc "$script_file" >/dev/null 2>&1 ) || status=$?
    fi

    rm -rf "$run_dir"

    if [[ "$status" -eq 124 ]]; then
        # Fail closed. Falling back to text splitting after a timeout can mine
        # commands from branches that Bash never safely reached. Preserve any
        # events already emitted by modeled stubs, add uncertainty, and let the
        # parser convert this RUN into a REVIEW note instead of active packages.
        __d2f_msg="RUN shell interpretation timed out; active extraction skipped"
        printf 'UNCERTAIN	%s
' "$__d2f_msg" >> "$events_file"
        log_warn "$__d2f_msg"
        return 0
    fi

    [[ -s "$events_file" ]] && return 0
    return 1
}
