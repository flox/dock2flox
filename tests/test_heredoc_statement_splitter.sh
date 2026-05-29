#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/parser_dockerfile.heredoc-per-statement.sh
source "$ROOT/lib/parser_dockerfile.heredoc-per-statement.sh"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local got="$1" expected="$2" msg="$3"
    [[ "$got" == "$expected" ]] || fail "$msg: expected [$expected], got [$got]"
}

assert_no_parsed_run_exact() {
    local forbidden="$1" msg="$2" run
    for run in "${parsed_runs[@]}"; do
        [[ "$run" != "$forbidden" ]] || fail "$msg: unexpected standalone parse [$forbidden]"
    done
}

body_simple=$'apt-get update -qq\napt-get install -y \\\n  curl \\\n  git\n/opt/custom/bin/tool setup\nrm -rf /var/lib/apt/lists'
statements=()
_d2f_split_heredoc_run_statements "$body_simple" statements
assert_eq "${#statements[@]}" "4" "simple body statement count"
assert_eq "${statements[1]}" "apt-get install -y    curl    git" "line continuation folding"
assert_eq "${statements[2]}" "/opt/custom/bin/tool setup" "path-addressed statement kept separate"

body_block=$'pkgs="wget"\nfor p in $pkgs; do\n  apt-get install -y "$p"\ndone\nif [[ -f /etc/debian_version ]]; then\n  apt-get install -y ca-certificates\nfi'
statements=()
_d2f_split_heredoc_run_statements "$body_block" statements
assert_eq "${#statements[@]}" "3" "compound body statement count"
assert_eq "${statements[0]}" 'pkgs="wget"' "assignment is standalone context candidate"
assert_eq "${statements[1]}" $'for p in $pkgs; do\n  apt-get install -y "$p"\ndone' "for block kept intact"
assert_eq "${statements[2]}" $'if [[ -f /etc/debian_version ]]; then\n  apt-get install -y ca-certificates\nfi' "if block kept intact"

body_arg_with_keyword=$'apt-get install -y for\napt-get install -y curl'
statements=()
_d2f_split_heredoc_run_statements "$body_arg_with_keyword" statements
assert_eq "${#statements[@]}" "2" "control keywords in argument position do not open a block"

body_echo_if=$'echo if\napt-get install -y curl'
statements=()
_d2f_split_heredoc_run_statements "$body_echo_if" statements
assert_eq "${#statements[@]}" "2" "echo argument named if does not merge following statement"
assert_eq "${statements[0]}" 'echo if' "echo if remains standalone"
assert_eq "${statements[1]}" 'apt-get install -y curl' "statement after echo if remains standalone"

body_quoted_control_words=$'echo "if"\nprintf %s done\napt-get install -y curl'
statements=()
_d2f_split_heredoc_run_statements "$body_quoted_control_words" statements
assert_eq "${#statements[@]}" "3" "quoted and argument-position control words do not affect depth"

body_one_line_if=$'if true; then apt-get install -y curl; fi\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_one_line_if" statements
assert_eq "${#statements[@]}" "2" "one-line if closes before next top-level statement"
assert_eq "${statements[0]}" 'if true; then apt-get install -y curl; fi' "one-line if statement body"

body_echo_then_if=$'echo start; if true; then\n  apt-get install -y curl\nfi\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_echo_then_if" statements
assert_eq "${#statements[@]}" "2" "compound command after separator opens depth"
assert_eq "${statements[0]}" $'echo start; if true; then\n  apt-get install -y curl\nfi' "compound after separator kept intact"

body_function_group=$'foo() {
  apt-get install -y curl
}
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_function_group" statements
assert_eq "${#statements[@]}" "2" "function body kept as one rejected-group statement"
assert_eq "${statements[0]}" $'foo() {
  apt-get install -y curl
}' "function body inner command not split out"
assert_eq "${statements[1]}" 'apt-get install -y git' "statement after function remains standalone"

body_function_keyword=$'function foo {
  apt-get install -y curl
}
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_function_keyword" statements
assert_eq "${#statements[@]}" "2" "function keyword body kept as one rejected-group statement"
assert_eq "${statements[0]}" $'function foo {
  apt-get install -y curl
}' "function keyword body inner command not split out"

body_brace_group=$'{
  apt-get install -y curl
}
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_brace_group" statements
assert_eq "${#statements[@]}" "2" "brace group kept as one rejected-group statement"
assert_eq "${statements[0]}" $'{
  apt-get install -y curl
}' "brace group inner command not split out"
assert_eq "${statements[1]}" 'apt-get install -y git' "statement after brace group remains standalone"

body_subshell_group=$'(
  apt-get install -y curl
)
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_subshell_group" statements
assert_eq "${#statements[@]}" "2" "subshell group kept as one rejected-group statement"
assert_eq "${statements[0]}" $'(
  apt-get install -y curl
)' "subshell inner command not split out"
assert_eq "${statements[1]}" 'apt-get install -y git' "statement after subshell remains standalone"

body_one_line_subshell_colon_tight=$'(:)
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_one_line_subshell_colon_tight" statements
assert_eq "${#statements[@]}" "2" "tight one-line subshell closes before following statement"
assert_eq "${statements[0]}" '(:)' "tight one-line subshell statement"
assert_eq "${statements[1]}" 'apt-get install -y git' "statement after tight one-line subshell remains standalone"

body_one_line_subshell_colon_spaced=$'( : )
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_one_line_subshell_colon_spaced" statements
assert_eq "${#statements[@]}" "2" "spaced one-line subshell closes before following statement"
assert_eq "${statements[0]}" '( : )' "spaced one-line subshell statement"
assert_eq "${statements[1]}" 'apt-get install -y git' "statement after spaced one-line subshell remains standalone"

body_one_line_subshell_install=$'( apt-get install -y curl )
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_one_line_subshell_install" statements
assert_eq "${#statements[@]}" "2" "one-line subshell with command closes before following statement"
assert_eq "${statements[0]}" '( apt-get install -y curl )' "one-line subshell command statement"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level install after one-line subshell remains standalone"

body_echo_unsupported_tokens=$'echo {
echo (
echo foo() {
apt-get install -y curl'
statements=()
_d2f_split_heredoc_run_statements "$body_echo_unsupported_tokens" statements
assert_eq "${#statements[@]}" "4" "unsupported group tokens in argument position do not affect depth"

body_multiline_double_quote=$'echo "\napt-get install -y curl\n"\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_multiline_double_quote" statements
assert_eq "${#statements[@]}" "2" "multiline double-quoted string does not split on interior command-like line"
assert_eq "${statements[0]}" $'echo "\napt-get install -y curl\n"' "double-quoted multiline statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level statement after double quote remains standalone"

body_multiline_single_quote=$'echo \'\napt-get install -y curl\n\'\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_multiline_single_quote" statements
assert_eq "${#statements[@]}" "2" "multiline single-quoted string does not split on interior command-like line"
assert_eq "${statements[0]}" $'echo \'\napt-get install -y curl\n\'' "single-quoted multiline statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level statement after single quote remains standalone"

body_multiline_cmd_sub=$'echo $(\napt-get install -y curl\n)\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_multiline_cmd_sub" statements
assert_eq "${#statements[@]}" "2" "multiline command substitution does not split on interior command-like line"
assert_eq "${statements[0]}" $'echo $(\napt-get install -y curl\n)' "command substitution statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level statement after command substitution remains standalone"

body_multiline_backtick=$'echo `\napt-get install -y curl\n`\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_multiline_backtick" statements
assert_eq "${#statements[@]}" "2" "multiline backtick substitution does not split on interior command-like line"
assert_eq "${statements[0]}" $'echo `\napt-get install -y curl\n`' "backtick substitution statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level statement after backtick remains standalone"

body_multiline_arith=$'echo $(( \n1 + 2\n))\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_multiline_arith" statements
assert_eq "${#statements[@]}" "2" "multiline arithmetic substitution does not split on interior line"
assert_eq "${statements[0]}" $'echo $(( \n1 + 2\n))' "arithmetic substitution statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level statement after arithmetic substitution remains standalone"



body_unquoted_cmd_sub_inner_double_quote=$'echo $(printf "x")
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_unquoted_cmd_sub_inner_double_quote" statements
assert_eq "${#statements[@]}" "2" "unquoted command substitution with inner double quotes closes before following statement"
assert_eq "${statements[0]}" 'echo $(printf "x")' "command substitution with inner double quotes remains one statement"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level install after unquoted command substitution remains standalone"

body_double_quoted_cmd_sub_inner_double_quote=$'echo "$(printf "x")"
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_double_quoted_cmd_sub_inner_double_quote" statements
assert_eq "${#statements[@]}" "2" "double-quoted command substitution with inner double quotes closes before following statement"
assert_eq "${statements[0]}" 'echo "$(printf "x")"' "double-quoted command substitution remains one statement"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level install after double-quoted command substitution remains standalone"

body_multiline_process_sub_input=$'cat <(\napt-get install -y curl\n)\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_multiline_process_sub_input" statements
assert_eq "${#statements[@]}" "2" "multiline input process substitution does not split on interior command-like line"
assert_eq "${statements[0]}" $'cat <(\napt-get install -y curl\n)' "input process substitution statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level statement after input process substitution remains standalone"

body_multiline_process_sub_output=$'cat >(\napt-get install -y curl\n)\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_multiline_process_sub_output" statements
assert_eq "${#statements[@]}" "2" "multiline output process substitution does not split on interior command-like line"
assert_eq "${statements[0]}" $'cat >(\napt-get install -y curl\n)' "output process substitution statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level statement after output process substitution remains standalone"

body_quoted_reserved_tokens=$'echo "if then fi { } ( )"\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_quoted_reserved_tokens" statements
assert_eq "${#statements[@]}" "2" "quoted reserved words and grouping tokens do not affect depth"
assert_eq "${statements[1]}" 'apt-get install -y git' "statement after quoted reserved tokens remains standalone"

body_nested_cmd_sub=$'echo "$(echo $(date))"\napt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_nested_cmd_sub" statements
assert_eq "${#statements[@]}" "2" "nested command substitution inside quotes stays inside first statement"
assert_eq "${statements[0]}" 'echo "$(echo $(date))"' "nested command substitution statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "statement after nested command substitution remains standalone"

_d2f_heredoc_statement_is_context 'set -eux' || fail 'set -eux recognized as context'
_d2f_heredoc_statement_is_context 'set -euo pipefail' || fail 'set -euo pipefail recognized as context'
_d2f_heredoc_statement_is_context 'set -o pipefail' || fail 'set -o pipefail recognized as context'
if _d2f_heredoc_statement_is_context 'set -eux; apt-get install -y curl'; then
    fail 'set followed by semicolon command must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'set -e && apt-get install -y curl'; then
    fail 'set followed by && command must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'set -e | cat'; then
    fail 'set in a pipeline must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'set -e > /tmp/out'; then
    fail 'set with redirection must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'set -e apt-get install -y curl'; then
    fail 'set with non-option words must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'set -o'; then
    fail 'set -o without an option name must not be context-only'
fi
_d2f_heredoc_statement_is_context 'pkgs="wget"' || fail 'simple assignment recognized as context'
_d2f_heredoc_statement_is_context 'PKGS="curl git"' || fail 'quoted assignment with spaces recognized as context'
_d2f_heredoc_statement_is_context "PKGS='curl git'" || fail 'single-quoted assignment with spaces recognized as context'
_d2f_heredoc_statement_is_context 'PKGS=curl\ git' || fail 'escaped-space assignment recognized as context'
_d2f_heredoc_statement_is_context 'A=1 B="two words"' || fail 'multiple assignment words recognized as context'
_d2f_heredoc_statement_is_context 'export PKGS="curl git" OTHER=ok' || fail 'export assignment context recognized'
_d2f_heredoc_statement_is_context 'EMPTY=' || fail 'empty assignment recognized as context'
if _d2f_heredoc_statement_is_context 'FOO=bar apt-get install -y curl'; then
    fail 'environment assignment before command must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'PATH=/tmp/bin'; then
    fail 'PATH assignment must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'BASH_ENV=/tmp/profile'; then
    fail 'BASH_ENV assignment must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'export PATH=/tmp/bin'; then
    fail 'export PATH assignment must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'export FOO=bar PATH=/tmp/bin'; then
    fail 'export with PATH assignment must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'export BASH_ENV=/tmp/profile'; then
    fail 'export BASH_ENV assignment must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'export FOO'; then
    fail 'export without assignment must not be context-only'
fi
if _d2f_heredoc_statement_is_context 'PKGS="curl git'; then
    fail 'unbalanced quoted assignment must not be context-only'
fi

_d2f_run_body_has_shell_heredoc_operator 'cat <<EOF' || fail 'shell heredoc operator recognized'
_d2f_run_body_has_shell_heredoc_operator 'cat <<-EOF' || fail 'dash heredoc operator recognized'
if _d2f_run_body_has_shell_heredoc_operator 'printf "<<EOF"'; then
    fail 'quoted heredoc operator ignored'
fi
if _d2f_run_body_has_shell_heredoc_operator 'cat <<< "apt-get install -y curl"'; then
    fail 'here-string with quoted payload must not be treated as nested shell heredoc'
fi
if _d2f_run_body_has_shell_heredoc_operator 'cat <<<$VALUE'; then
    fail 'here-string with variable payload must not be treated as nested shell heredoc'
fi
if _d2f_run_body_has_shell_heredoc_operator 'echo $((1 << 2))'; then
    fail 'arithmetic left shift with spaces must not be treated as nested shell heredoc'
fi
if _d2f_run_body_has_shell_heredoc_operator 'echo $((1<<2))'; then
    fail 'arithmetic left shift without spaces must not be treated as nested shell heredoc'
fi
if _d2f_run_body_has_shell_heredoc_operator $'# cat <<EOF
/opt/foo
apt-get install -y git'; then
    fail 'comment-only nested heredoc text must not force whole-body fallback'
fi
if _d2f_run_body_has_shell_heredoc_operator $'echo ok # cat <<EOF
/opt/foo
apt-get install -y git'; then
    fail 'trailing comment nested heredoc text must not force whole-body fallback'
fi
_d2f_run_body_has_shell_heredoc_operator 'cat <<INNER' || fail 'true nested shell heredoc operator still recognized'

body_here_string_quoted=$'cat <<< "apt-get install -y curl"
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_here_string_quoted" statements
assert_eq "${#statements[@]}" "2" "here-string with quoted command-like payload splits from following top-level statement"
assert_eq "${statements[0]}" 'cat <<< "apt-get install -y curl"' "here-string statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level install after here-string remains standalone"

body_here_string_variable=$'cat <<<$VALUE
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_here_string_variable" statements
assert_eq "${#statements[@]}" "2" "here-string with variable payload splits from following top-level statement"
assert_eq "${statements[0]}" 'cat <<<$VALUE' "here-string variable statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level install after variable here-string remains standalone"

body_arith_shift_spaced=$'echo $((1 << 2))
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_arith_shift_spaced" statements
assert_eq "${#statements[@]}" "2" "arithmetic left shift with spaces splits from following top-level statement"
assert_eq "${statements[0]}" 'echo $((1 << 2))' "arithmetic shift statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level install after arithmetic shift remains standalone"

body_arith_shift_compact=$'echo $((1<<2))
apt-get install -y git'
statements=()
_d2f_split_heredoc_run_statements "$body_arith_shift_compact" statements
assert_eq "${#statements[@]}" "2" "arithmetic left shift without spaces splits from following top-level statement"
assert_eq "${statements[0]}" 'echo $((1<<2))' "compact arithmetic shift statement kept intact"
assert_eq "${statements[1]}" 'apt-get install -y git' "top-level install after compact arithmetic shift remains standalone"


parsed_runs=()
review_records=()
hook_records=()
_parse_run() {
    parsed_runs+=("$1")
}
_run_body_safe_subset_issue() {
    return 1
}
_run_body_safety_issue() {
    return 1
}
ir_review() {
    review_records+=("$2|$3")
}
ir_hook() {
    hook_records+=("$3")
}

parsed_runs=(); review_records=(); hook_records=()
context_only_body=$'PKGS="curl git"'
_parse_run_heredoc_per_statement "$context_only_body" /tmp/d2f-ir 42
assert_eq "${#parsed_runs[@]}" "0" "context-only heredoc must not invoke parse path"
assert_eq "${#review_records[@]}" "1" "context-only heredoc emits one review record"
assert_eq "${#hook_records[@]}" "1" "context-only heredoc emits one RUN comment"
case "${hook_records[0]}" in
    *'PKGS="curl git"'*) : ;;
    *) fail 'context-only heredoc RUN comment must include the original assignment' ;;
esac

parsed_runs=(); review_records=(); hook_records=()
context_then_action_body=$'PKGS="curl git"\napt-get install -y $PKGS'
_parse_run_heredoc_per_statement "$context_then_action_body" /tmp/d2f-ir 43
assert_eq "${#parsed_runs[@]}" "1" "context before action parsed once"
assert_eq "${parsed_runs[0]}" $'RUN PKGS="curl git"\napt-get install -y $PKGS' "context prefixes later action"
assert_eq "${#review_records[@]}" "0" "consumed context emits no review"
assert_eq "${#hook_records[@]}" "0" "consumed context emits no RUN comment"

parsed_runs=(); review_records=(); hook_records=()
action_then_context_body=$'apt-get update\nPKGS="curl git"'
_parse_run_heredoc_per_statement "$action_then_context_body" /tmp/d2f-ir 44
assert_eq "${#parsed_runs[@]}" "1" "action before context parsed once"
assert_eq "${parsed_runs[0]}" 'RUN apt-get update' "action before context parse body"
assert_eq "${#review_records[@]}" "1" "trailing context emits one review record"
assert_eq "${#hook_records[@]}" "1" "trailing context emits one RUN comment"
case "${hook_records[0]}" in
    *'PKGS="curl git"'*) : ;;
    *) fail 'trailing context RUN comment must include the original assignment' ;;
esac

parsed_runs=(); review_records=(); hook_records=()
set_chain_body='set -eux; apt-get install -y curl'
_parse_run_heredoc_per_statement "$set_chain_body" /tmp/d2f-ir 45
assert_eq "${#parsed_runs[@]}" "1" "set semicolon chain parsed as actionable"
assert_eq "${parsed_runs[0]}" 'RUN set -eux; apt-get install -y curl' "set semicolon chain parse body"
assert_eq "${#review_records[@]}" "0" "set semicolon chain does not emit context review"
assert_eq "${#hook_records[@]}" "0" "set semicolon chain does not emit context comment"

parsed_runs=(); review_records=(); hook_records=()
set_and_body='set -e && apt-get install -y curl'
_parse_run_heredoc_per_statement "$set_and_body" /tmp/d2f-ir 46
assert_eq "${#parsed_runs[@]}" "1" "set && chain parsed as actionable"
assert_eq "${parsed_runs[0]}" 'RUN set -e && apt-get install -y curl' "set && chain parse body"

parsed_runs=(); review_records=(); hook_records=()
set_pipe_body='set -e | cat'
_parse_run_heredoc_per_statement "$set_pipe_body" /tmp/d2f-ir 47
assert_eq "${#parsed_runs[@]}" "1" "set pipeline parsed as actionable"
assert_eq "${parsed_runs[0]}" 'RUN set -e | cat' "set pipeline parse body"


parsed_runs=(); review_records=(); hook_records=()
lexical_dispatch_body=$'echo "\napt-get install -y curl\n"\napt-get install -y git'
_parse_run_heredoc_per_statement "$lexical_dispatch_body" /tmp/d2f-ir 48
assert_eq "${#parsed_runs[@]}" "2" "multiline double quote dispatches two top-level statements"
assert_no_parsed_run_exact 'RUN apt-get install -y curl' "double quote interior command-like line must not be dispatched"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after double quote is dispatched"

parsed_runs=(); review_records=(); hook_records=()
cmd_sub_dispatch_body=$'echo $(\napt-get install -y curl\n)\napt-get install -y git'
_parse_run_heredoc_per_statement "$cmd_sub_dispatch_body" /tmp/d2f-ir 49
assert_eq "${#parsed_runs[@]}" "2" "multiline command substitution dispatches two top-level statements"
assert_no_parsed_run_exact 'RUN apt-get install -y curl' "command substitution interior command-like line must not be dispatched"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after command substitution is dispatched"

parsed_runs=(); review_records=(); hook_records=()
backtick_dispatch_body=$'echo `\napt-get install -y curl\n`\napt-get install -y git'
_parse_run_heredoc_per_statement "$backtick_dispatch_body" /tmp/d2f-ir 50
assert_eq "${#parsed_runs[@]}" "2" "multiline backtick substitution dispatches two top-level statements"
assert_no_parsed_run_exact 'RUN apt-get install -y curl' "backtick interior command-like line must not be dispatched"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after backtick is dispatched"


parsed_runs=(); review_records=(); hook_records=()

parsed_runs=(); review_records=(); hook_records=()
unquoted_cmd_sub_inner_double_quote_dispatch_body=$'echo $(printf "x")
apt-get install -y git'
_parse_run_heredoc_per_statement "$unquoted_cmd_sub_inner_double_quote_dispatch_body" /tmp/d2f-ir 53
assert_eq "${#parsed_runs[@]}" "2" "unquoted command substitution with inner double quotes dispatches two top-level statements"
assert_eq "${parsed_runs[0]}" 'RUN echo $(printf "x")' "unsupported command substitution remains isolated"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after command substitution is dispatched"

parsed_runs=(); review_records=(); hook_records=()
process_sub_input_dispatch_body=$'cat <(\napt-get install -y curl\n)\napt-get install -y git'
_parse_run_heredoc_per_statement "$process_sub_input_dispatch_body" /tmp/d2f-ir 51
assert_eq "${#parsed_runs[@]}" "2" "multiline input process substitution dispatches two top-level statements"
assert_no_parsed_run_exact 'RUN apt-get install -y curl' "input process substitution interior command-like line must not be dispatched"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after input process substitution is dispatched"

parsed_runs=(); review_records=(); hook_records=()
process_sub_output_dispatch_body=$'cat >(\napt-get install -y curl\n)\napt-get install -y git'
_parse_run_heredoc_per_statement "$process_sub_output_dispatch_body" /tmp/d2f-ir 52
assert_eq "${#parsed_runs[@]}" "2" "multiline output process substitution dispatches two top-level statements"
assert_no_parsed_run_exact 'RUN apt-get install -y curl' "output process substitution interior command-like line must not be dispatched"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after output process substitution is dispatched"

parsed_runs=(); review_records=(); hook_records=()
here_string_quoted_dispatch_body=$'cat <<< "apt-get install -y curl"
apt-get install -y git'
_parse_run_heredoc_per_statement "$here_string_quoted_dispatch_body" /tmp/d2f-ir 54
assert_eq "${#parsed_runs[@]}" "2" "here-string with quoted command-like text dispatches two top-level statements"
assert_eq "${parsed_runs[0]}" 'RUN cat <<< "apt-get install -y curl"' "here-string statement remains isolated"
assert_no_parsed_run_exact 'RUN apt-get install -y curl' "here-string payload command-like text must not be dispatched"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after quoted here-string is dispatched"

parsed_runs=(); review_records=(); hook_records=()
here_string_variable_dispatch_body=$'cat <<<$VALUE
apt-get install -y git'
_parse_run_heredoc_per_statement "$here_string_variable_dispatch_body" /tmp/d2f-ir 55
assert_eq "${#parsed_runs[@]}" "2" "here-string with variable payload dispatches two top-level statements"
assert_eq "${parsed_runs[0]}" 'RUN cat <<<$VALUE' "variable here-string statement remains isolated"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after variable here-string is dispatched"

parsed_runs=(); review_records=(); hook_records=()
nested_shell_heredoc_dispatch_body=$'cat <<INNER
apt-get install -y curl
INNER
apt-get install -y git'
_parse_run_heredoc_per_statement "$nested_shell_heredoc_dispatch_body" /tmp/d2f-ir 56
assert_eq "${#parsed_runs[@]}" "1" "true nested shell heredoc falls back to whole-body processing"
assert_eq "${parsed_runs[0]}" $'RUN cat <<INNER
apt-get install -y curl
INNER
apt-get install -y git' "nested shell heredoc body remains one statement"

parsed_runs=(); review_records=(); hook_records=()
arith_shift_spaced_dispatch_body=$'echo $((1 << 2))
apt-get install -y git'
_parse_run_heredoc_per_statement "$arith_shift_spaced_dispatch_body" /tmp/d2f-ir 57
assert_eq "${#parsed_runs[@]}" "2" "arithmetic left shift with spaces dispatches two top-level statements"
assert_eq "${parsed_runs[0]}" 'RUN echo $((1 << 2))' "arithmetic shift statement remains isolated"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after arithmetic shift is dispatched"

parsed_runs=(); review_records=(); hook_records=()
arith_shift_compact_dispatch_body=$'echo $((1<<2))
apt-get install -y git'
_parse_run_heredoc_per_statement "$arith_shift_compact_dispatch_body" /tmp/d2f-ir 58
assert_eq "${#parsed_runs[@]}" "2" "arithmetic left shift without spaces dispatches two top-level statements"
assert_eq "${parsed_runs[0]}" 'RUN echo $((1<<2))' "compact arithmetic shift statement remains isolated"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after compact arithmetic shift is dispatched"


parsed_runs=(); review_records=(); hook_records=()
comment_only_heredoc_text_body=$'# cat <<EOF
/opt/foo
apt-get install -y git'
_parse_run_heredoc_per_statement "$comment_only_heredoc_text_body" /tmp/d2f-ir 59
assert_eq "${#parsed_runs[@]}" "2" "comment-only heredoc text does not force whole-body fallback"
assert_eq "${parsed_runs[0]}" 'RUN /opt/foo' "path-addressed statement after comment remains isolated"
assert_eq "${parsed_runs[1]}" 'RUN apt-get install -y git' "top-level install after comment and path statement is dispatched"

parsed_runs=(); review_records=(); hook_records=()
trailing_comment_heredoc_text_body=$'echo ok # cat <<EOF
/opt/foo
apt-get install -y git'
_parse_run_heredoc_per_statement "$trailing_comment_heredoc_text_body" /tmp/d2f-ir 60
assert_eq "${#parsed_runs[@]}" "3" "trailing comment heredoc text does not force whole-body fallback"
assert_eq "${parsed_runs[0]}" 'RUN echo ok # cat <<EOF' "statement with trailing comment remains isolated"
assert_eq "${parsed_runs[1]}" 'RUN /opt/foo' "path-addressed statement after trailing comment remains isolated"
assert_eq "${parsed_runs[2]}" 'RUN apt-get install -y git' "top-level install after trailing comment and path statement is dispatched"

printf 'ok - heredoc statement splitter tests passed\n'
