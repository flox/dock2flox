#!/usr/bin/env bash
# Per-statement Dockerfile heredoc RUN processing for dock2flox.
#
# Intended integration point: lib/parser_dockerfile.sh.
# The patch in patches/0001-per-statement-heredoc-run.patch contains the
# exact source edit. This file mirrors the helper functions for review and
# standalone splitter tests.

_d2f_run_body_encoded_from_heredoc() {
    local encoded_body="$1"
    [[ "$encoded_body" == *$'\x1e'* ]]
}

_d2f_shell_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Return true if BODY contains a shell heredoc operator (<< or <<-) outside
# single and double quotes, outside comments, and outside arithmetic
# substitution. In that case, keep the legacy whole-RUN path; splitting
# nested shell heredoc data as shell statements would be unsound. Here-strings
# (<<<) and arithmetic left shifts inside $((...)) are not heredoc operators.
_d2f_run_body_has_shell_heredoc_operator() {
    local body="$1"
    local i=0 len=${#body} ch next next2 state="none" arith_paren_depth=0

    while [[ "$i" -lt "$len" ]]; do
        ch="${body:$i:1}"
        next=""
        next2=""
        if [[ $((i + 1)) -lt "$len" ]]; then
            next="${body:$((i + 1)):1}"
        fi
        if [[ $((i + 2)) -lt "$len" ]]; then
            next2="${body:$((i + 2)):1}"
        fi

        case "$state" in
            single)
                [[ "$ch" == "'" ]] && state="none"
                i=$((i + 1))
                continue
                ;;
            double)
                if [[ "$ch" == "\\" ]]; then
                    i=$((i + 2))
                    continue
                fi
                [[ "$ch" == '"' ]] && state="none"
                i=$((i + 1))
                continue
                ;;
            arith)
                if [[ "$ch" == "\\" ]]; then
                    i=$((i + 2))
                    continue
                fi
                case "$ch" in
                    '(')
                        arith_paren_depth=$((arith_paren_depth + 1))
                        ;;
                    ')')
                        if [[ "$arith_paren_depth" -gt 0 ]]; then
                            arith_paren_depth=$((arith_paren_depth - 1))
                        elif [[ "$next" == ')' ]]; then
                            state="none"
                            i=$((i + 2))
                            continue
                        fi
                        ;;
                esac
                i=$((i + 1))
                continue
                ;;
        esac

        if [[ "$ch" == '$' && "$next" == '(' && "$next2" == '(' ]]; then
            state="arith"
            arith_paren_depth=0
            i=$((i + 3))
            continue
        fi

        # Ignore real shell comments. A # starts a comment only when it is
        # unquoted and begins a word, which covers start-of-line, whitespace,
        # and common control-operator positions. Any << text after that point
        # is data for humans, not a nested shell heredoc operator.
        if [[ "$ch" == '#' ]]; then
            local prev=""
            if [[ "$i" -gt 0 ]]; then
                prev="${body:$((i - 1)):1}"
            fi
            if [[ "$i" -eq 0 || "$prev" == $'\n' || "$prev" =~ [[:space:]] || "$prev" == ';' || "$prev" == '&' || "$prev" == '|' || "$prev" == '(' || "$prev" == '{' ]]; then
                while [[ "$i" -lt "$len" && "${body:$i:1}" != $'\n' ]]; do
                    i=$((i + 1))
                done
                continue
            fi
        fi

        case "$ch" in
            "'") state="single" ;;
            '"') state="double" ;;
            "\\") i=$((i + 2)); continue ;;
            '<')
                if [[ "$next" == '<' ]]; then
                    # Shell here-strings use <<< and are ordinary redirections
                    # for this splitter. They should be reviewed as their own
                    # statement, not force a whole-body nested-heredoc fallback.
                    if [[ "$next2" == '<' ]]; then
                        i=$((i + 3))
                        continue
                    fi
                    return 0
                fi
                ;;
        esac
        i=$((i + 1))
    done

    return 1
}


# Apply one parsed shell token to the compound-command depth counter.
# Reserved words only count when they occur unquoted in command position. This
# avoids false block openings for ordinary arguments such as `echo if`.
_d2f_heredoc_apply_control_token() {
    local token="$1" token_quoted="$2"
    local -n _d2f_depth_ref="$3"
    local -n _d2f_expect_cmd_ref="$4"
    local -n _d2f_redir_target_ref="$5"

    [[ -n "$token" ]] || return 0

    if [[ "$_d2f_redir_target_ref" -eq 1 ]]; then
        _d2f_redir_target_ref=0
        return 0
    fi

    if [[ "$_d2f_expect_cmd_ref" -eq 1 && "$token_quoted" -eq 0 ]]; then
        case "$token" in
            if|for|while|until|case|select)
                _d2f_depth_ref=$((_d2f_depth_ref + 1))
                _d2f_expect_cmd_ref=0
                return 0
                ;;
            fi|done|esac)
                if [[ "$_d2f_depth_ref" -gt 0 ]]; then
                    _d2f_depth_ref=$((_d2f_depth_ref - 1))
                fi
                _d2f_expect_cmd_ref=0
                return 0
                ;;
            then|do|else|elif|in)
                _d2f_expect_cmd_ref=1
                return 0
                ;;
        esac
    fi

    if [[ "$_d2f_expect_cmd_ref" -eq 1 ]]; then
        if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            _d2f_expect_cmd_ref=1
        else
            _d2f_expect_cmd_ref=0
        fi
    fi
}

# Apply one parsed shell token to the unsupported-group depth counter.
# This tracks shell constructs that the existing safety gate rejects as a unit:
# function bodies, brace groups, and subshell groups. Keeping those groups
# intact prevents extracting commands that appear inside syntax the parser does
# not model.
_d2f_heredoc_apply_unsupported_token() {
    local token="$1" token_quoted="$2"
    local -n _d2f_group_depth_ref="$3"
    local -n _d2f_func_state_ref="$4"
    local -n _d2f_expect_cmd_ref="$5"
    local -n _d2f_redir_target_ref="$6"

    [[ -n "$token" ]] || return 0

    if [[ "$_d2f_redir_target_ref" -eq 1 ]]; then
        _d2f_redir_target_ref=0
        return 0
    fi

    if [[ "$token_quoted" -eq 0 && "$_d2f_func_state_ref" -eq 1 ]]; then
        if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*(\(\))?$ ]]; then
            _d2f_func_state_ref=2
            _d2f_expect_cmd_ref=1
            return 0
        fi
        _d2f_func_state_ref=0
    fi

    if [[ "$_d2f_expect_cmd_ref" -eq 1 ]]; then
        if [[ "$token_quoted" -eq 0 ]]; then
            case "$token" in
                function)
                    _d2f_func_state_ref=1
                    _d2f_expect_cmd_ref=1
                    return 0
                    ;;
            esac
            if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)$ ]]; then
                _d2f_func_state_ref=2
                _d2f_expect_cmd_ref=1
                return 0
            fi
        fi

        if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            _d2f_expect_cmd_ref=1
        else
            _d2f_expect_cmd_ref=0
        fi
    fi
}

# Update rejected shell-group depth from one logical shell line. The scanner is
# quote-aware and command-position-aware, so arguments such as `echo {` or
# `echo foo() {` do not start a group. When it does identify a rejected group,
# the splitter keeps the entire group together for the existing safety gate.
_d2f_heredoc_update_unsupported_group_depth() {
    local line="$1"
    local -n _group_depth_ref="$2"
    local -n _func_state_ref="$3"
    local -n _subshell_depth_ref="$4"
    local i=0 len=${#line} ch next state="none" token=""
    local token_quoted=0 expect_cmd=1 redir_target=0

    while [[ "$i" -lt "$len" ]]; do
        ch="${line:$i:1}"
        next=""
        if [[ $((i + 1)) -lt "$len" ]]; then
            next="${line:$((i + 1)):1}"
        fi

        case "$state" in
            single)
                if [[ "$ch" == "'" ]]; then
                    state="none"
                else
                    token+="$ch"
                fi
                i=$((i + 1))
                continue
                ;;
            double)
                case "$ch" in
                    '"') state="none" ;;
                    "\\")
                        token_quoted=1
                        if [[ -n "$next" ]]; then
                            token+="$next"
                            i=$((i + 2))
                            continue
                        fi
                        token+="$ch"
                        ;;
                    *) token+="$ch" ;;
                esac
                i=$((i + 1))
                continue
                ;;
        esac

        case "$ch" in
            [[:space:]])
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_unsupported_token "$token" "$token_quoted" _group_depth_ref _func_state_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                ;;
            "'")
                state="single"
                token_quoted=1
                ;;
            '"')
                state="double"
                token_quoted=1
                ;;
            "\\")
                token_quoted=1
                if [[ -n "$next" ]]; then
                    token+="$next"
                    i=$((i + 2))
                    continue
                fi
                token+="$ch"
                ;;
            '#')
                if [[ -z "$token" ]]; then
                    break
                fi
                token+="$ch"
                ;;
            ';'|'|'|'&')
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_unsupported_token "$token" "$token_quoted" _group_depth_ref _func_state_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                expect_cmd=1
                redir_target=0
                if [[ "$next" == "$ch" ]]; then
                    i=$((i + 1))
                fi
                ;;
            '<'|'>')
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_unsupported_token "$token" "$token_quoted" _group_depth_ref _func_state_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                redir_target=1
                if [[ "$next" == "$ch" ]]; then
                    i=$((i + 1))
                fi
                ;;
            '{')
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_unsupported_token "$token" "$token_quoted" _group_depth_ref _func_state_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                if [[ "$redir_target" -eq 1 ]]; then
                    redir_target=0
                elif [[ "$token_quoted" -eq 0 && ( "$_func_state_ref" -eq 2 || "$expect_cmd" -eq 1 ) ]]; then
                    _group_depth_ref=$((_group_depth_ref + 1))
                    _func_state_ref=0
                    expect_cmd=1
                fi
                ;;
            '}')
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_unsupported_token "$token" "$token_quoted" _group_depth_ref _func_state_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                if [[ "$redir_target" -eq 1 ]]; then
                    redir_target=0
                elif [[ "$expect_cmd" -eq 1 && "$_group_depth_ref" -gt 0 ]]; then
                    _group_depth_ref=$((_group_depth_ref - 1))
                    expect_cmd=0
                fi
                ;;
            '(')
                if [[ -z "$token" && "$expect_cmd" -eq 1 && "$_func_state_ref" -ne 2 ]]; then
                    _group_depth_ref=$((_group_depth_ref + 1))
                    _subshell_depth_ref=$((_subshell_depth_ref + 1))
                    expect_cmd=1
                else
                    token+="$ch"
                fi
                ;;
            ')')
                if [[ "$_subshell_depth_ref" -gt 0 ]]; then
                    if [[ -n "$token" ]]; then
                        _d2f_heredoc_apply_unsupported_token "$token" "$token_quoted" _group_depth_ref _func_state_ref expect_cmd redir_target
                        token=""
                        token_quoted=0
                    fi
                    _subshell_depth_ref=$((_subshell_depth_ref - 1))
                    _group_depth_ref=$((_group_depth_ref - 1))
                    expect_cmd=0
                    redir_target=0
                elif [[ "$token" == *'('* ]]; then
                    token+=")"
                else
                    token+=")"
                fi
                ;;
            *)
                token+="$ch"
                ;;
        esac
        i=$((i + 1))
    done

    if [[ -n "$token" ]]; then
        _d2f_heredoc_apply_unsupported_token "$token" "$token_quoted" _group_depth_ref _func_state_ref expect_cmd redir_target
    fi

    [[ "$_group_depth_ref" -ge 0 ]] || _group_depth_ref=0
    [[ "$_subshell_depth_ref" -ge 0 ]] || _subshell_depth_ref=0
}

# Update a small compound-command depth counter from one logical shell line.
# The scanner is intentionally limited, but it is shell-aware enough for the
# splitting decision: it tracks quotes, comments, command separators, redirection
# targets, and command-position reserved words. The existing safety gate remains
# the authority before any statement reaches the interpreter.
_d2f_heredoc_update_shell_depth() {
    local line="$1"
    local -n _depth_ref="$2"
    local i=0 len=${#line} ch next state="none" token=""
    local token_quoted=0 expect_cmd=1 redir_target=0

    while [[ "$i" -lt "$len" ]]; do
        ch="${line:$i:1}"
        next=""
        if [[ $((i + 1)) -lt "$len" ]]; then
            next="${line:$((i + 1)):1}"
        fi

        case "$state" in
            single)
                if [[ "$ch" == "'" ]]; then
                    state="none"
                else
                    token+="$ch"
                fi
                i=$((i + 1))
                continue
                ;;
            double)
                case "$ch" in
                    '"')
                        state="none"
                        ;;
                    "\\")
                        token_quoted=1
                        if [[ -n "$next" ]]; then
                            token+="$next"
                            i=$((i + 2))
                            continue
                        fi
                        token+="$ch"
                        ;;
                    *)
                        token+="$ch"
                        ;;
                esac
                i=$((i + 1))
                continue
                ;;
        esac

        case "$ch" in
            [[:space:]])
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_control_token "$token" "$token_quoted" _depth_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                ;;
            "'")
                state="single"
                token_quoted=1
                ;;
            '"')
                state="double"
                token_quoted=1
                ;;
            "\\")
                token_quoted=1
                if [[ -n "$next" ]]; then
                    token+="$next"
                    i=$((i + 2))
                    continue
                fi
                token+="$ch"
                ;;
            '#')
                if [[ -z "$token" ]]; then
                    break
                fi
                token+="$ch"
                ;;
            ';')
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_control_token "$token" "$token_quoted" _depth_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                expect_cmd=1
                redir_target=0
                ;;
            '|'|'&')
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_control_token "$token" "$token_quoted" _depth_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                expect_cmd=1
                redir_target=0
                if [[ "$next" == "$ch" ]]; then
                    i=$((i + 1))
                fi
                ;;
            '<'|'>')
                if [[ -n "$token" ]]; then
                    _d2f_heredoc_apply_control_token "$token" "$token_quoted" _depth_ref expect_cmd redir_target
                    token=""
                    token_quoted=0
                fi
                redir_target=1
                if [[ "$next" == "$ch" ]]; then
                    i=$((i + 1))
                fi
                ;;
            *)
                token+="$ch"
                ;;
        esac
        i=$((i + 1))
    done

    if [[ -n "$token" ]]; then
        _d2f_heredoc_apply_control_token "$token" "$token_quoted" _depth_ref expect_cmd redir_target
    fi

    [[ "$_depth_ref" -ge 0 ]] || _depth_ref=0
}

# Update multiline lexical state used by the heredoc splitter. Newlines are
# statement boundaries only when this state is fully closed. This stack-based
# scanner treats quoting and substitution scopes independently, so quotes inside
# command/process substitution cannot leak outward and hide the next top-level
# statement.
_d2f_heredoc_update_lexical_state() {
    local line="$1"
    local -n _quote_state_ref="$2"
    local -n _cmd_sub_depth_ref="$3"
    local -n _arith_sub_depth_ref="$4"
    local -n _process_sub_depth_ref="$5"
    local i=0 len=${#line} ch next next2 stack="" top item rest

    case "$_quote_state_ref" in
        none|"") stack="" ;;
        STACK:*) stack="${_quote_state_ref#STACK:}" ;;
        single) stack="SQ" ;;
        double) stack="DQ" ;;
        backtick|double_backtick) stack="BT" ;;
        *) stack="$_quote_state_ref" ;;
    esac

    while [[ "$i" -lt "$len" ]]; do
        ch="${line:$i:1}"
        next=""
        next2=""
        if [[ $((i + 1)) -lt "$len" ]]; then
            next="${line:$((i + 1)):1}"
        fi
        if [[ $((i + 2)) -lt "$len" ]]; then
            next2="${line:$((i + 2)):1}"
        fi

        if [[ -z "$stack" ]]; then
            top="none"
        else
            top="${stack##*|}"
        fi

        case "$top" in
            SQ)
                if [[ "$ch" == "'" ]]; then
                    if [[ "$stack" == *'|'* ]]; then stack="${stack%|*}"; else stack=""; fi
                fi
                i=$((i + 1))
                continue
                ;;
            DQ)
                case "$ch" in
                    '"')
                        if [[ "$stack" == *'|'* ]]; then stack="${stack%|*}"; else stack=""; fi
                        ;;
                    "\\")
                        i=$((i + 2))
                        continue
                        ;;
                    '`')
                        if [[ -z "$stack" ]]; then stack="BT"; else stack+="|BT"; fi
                        ;;
                    '$')
                        if [[ "$next" == '(' && "$next2" == '(' ]]; then
                            if [[ -z "$stack" ]]; then stack="ARITH"; else stack+="|ARITH"; fi
                            i=$((i + 3))
                            continue
                        fi
                        if [[ "$next" == '(' ]]; then
                            if [[ -z "$stack" ]]; then stack="CMD"; else stack+="|CMD"; fi
                            i=$((i + 2))
                            continue
                        fi
                        ;;
                esac
                i=$((i + 1))
                continue
                ;;
            BT)
                if [[ "$ch" == "\\" ]]; then
                    i=$((i + 2))
                    continue
                fi
                if [[ "$ch" == '`' ]]; then
                    if [[ "$stack" == *'|'* ]]; then stack="${stack%|*}"; else stack=""; fi
                fi
                i=$((i + 1))
                continue
                ;;
            ARITH)
                if [[ "$ch" == "\\" ]]; then
                    i=$((i + 2))
                    continue
                fi
                if [[ "$ch" == '$' && "$next" == '(' && "$next2" == '(' ]]; then
                    if [[ -z "$stack" ]]; then stack="ARITH"; else stack+="|ARITH"; fi
                    i=$((i + 3))
                    continue
                fi
                if [[ "$ch" == ')' && "$next" == ')' ]]; then
                    if [[ "$stack" == *'|'* ]]; then stack="${stack%|*}"; else stack=""; fi
                    i=$((i + 2))
                    continue
                fi
                i=$((i + 1))
                continue
                ;;
            CMD|PROC|PAREN)
                case "$ch" in
                    "'")
                        if [[ -z "$stack" ]]; then stack="SQ"; else stack+="|SQ"; fi
                        ;;
                    '"')
                        if [[ -z "$stack" ]]; then stack="DQ"; else stack+="|DQ"; fi
                        ;;
                    '`')
                        if [[ -z "$stack" ]]; then stack="BT"; else stack+="|BT"; fi
                        ;;
                    "\\")
                        i=$((i + 2))
                        continue
                        ;;
                    '$')
                        if [[ "$next" == '(' && "$next2" == '(' ]]; then
                            if [[ -z "$stack" ]]; then stack="ARITH"; else stack+="|ARITH"; fi
                            i=$((i + 3))
                            continue
                        fi
                        if [[ "$next" == '(' ]]; then
                            if [[ -z "$stack" ]]; then stack="CMD"; else stack+="|CMD"; fi
                            i=$((i + 2))
                            continue
                        fi
                        ;;
                    '<'|'>')
                        if [[ "$next" == '(' ]]; then
                            if [[ -z "$stack" ]]; then stack="PROC"; else stack+="|PROC"; fi
                            i=$((i + 2))
                            continue
                        fi
                        ;;
                    '(')
                        if [[ -z "$stack" ]]; then stack="PAREN"; else stack+="|PAREN"; fi
                        ;;
                    ')')
                        if [[ "$stack" == *'|'* ]]; then stack="${stack%|*}"; else stack=""; fi
                        ;;
                esac
                i=$((i + 1))
                continue
                ;;
        esac

        case "$ch" in
            "'")
                if [[ -z "$stack" ]]; then stack="SQ"; else stack+="|SQ"; fi
                ;;
            '"')
                if [[ -z "$stack" ]]; then stack="DQ"; else stack+="|DQ"; fi
                ;;
            '`')
                if [[ -z "$stack" ]]; then stack="BT"; else stack+="|BT"; fi
                ;;
            "\\")
                i=$((i + 2))
                continue
                ;;
            '$')
                if [[ "$next" == '(' && "$next2" == '(' ]]; then
                    if [[ -z "$stack" ]]; then stack="ARITH"; else stack+="|ARITH"; fi
                    i=$((i + 3))
                    continue
                fi
                if [[ "$next" == '(' ]]; then
                    if [[ -z "$stack" ]]; then stack="CMD"; else stack+="|CMD"; fi
                    i=$((i + 2))
                    continue
                fi
                ;;
            '<'|'>')
                if [[ "$next" == '(' ]]; then
                    if [[ -z "$stack" ]]; then stack="PROC"; else stack+="|PROC"; fi
                    i=$((i + 2))
                    continue
                fi
                ;;
        esac
        i=$((i + 1))
    done

    _cmd_sub_depth_ref=0
    _arith_sub_depth_ref=0
    _process_sub_depth_ref=0
    rest="$stack"
    while [[ -n "$rest" ]]; do
        if [[ "$rest" == *'|'* ]]; then
            item="${rest%%|*}"
            rest="${rest#*|}"
        else
            item="$rest"
            rest=""
        fi
        case "$item" in
            CMD) _cmd_sub_depth_ref=$((_cmd_sub_depth_ref + 1)) ;;
            ARITH) _arith_sub_depth_ref=$((_arith_sub_depth_ref + 1)) ;;
            PROC) _process_sub_depth_ref=$((_process_sub_depth_ref + 1)) ;;
        esac
    done

    if [[ -z "$stack" ]]; then
        _quote_state_ref="none"
    else
        _quote_state_ref="STACK:$stack"
    fi
}

_d2f_heredoc_lexical_state_is_closed() {
    local quote_state="$1" cmd_sub_depth="$2" arith_sub_depth="$3" process_sub_depth="$4"
    [[ "$quote_state" == "none" && "$cmd_sub_depth" -eq 0 && "$arith_sub_depth" -eq 0 && "$process_sub_depth" -eq 0 ]]
}

# Split a Dockerfile heredoc RUN body into top-level shell statements.
# - Folds backslash-newline continuations into a single logical statement.
# - Keeps if/for/while/until/case/select blocks intact.
# - Leaves blank/comment-only lines as no-op statements for caller filtering.
_d2f_split_heredoc_run_statements() {
    local body="$1"
    local -n _out_statements="$2"
    local line logical="" current="" trimmed="" depth=0 group_depth=0 function_state=0 subshell_depth=0
    local prior_group_depth=0 prior_function_state=0 prior_subshell_depth=0
    local quote_state="none" cmd_sub_depth=0 arith_sub_depth=0 process_sub_depth=0
    local lexical_was_closed=1
    _out_statements=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *\\ ]]; then
            logical+="${line%\\} "
            continue
        fi
        logical+="$line"

        trimmed="$(_d2f_shell_trim "$logical")"

        if [[ -z "$trimmed" || "$trimmed" == \#* ]]; then
            if [[ -z "$current" && "$depth" -eq 0 && "$group_depth" -eq 0 && "$function_state" -eq 0 && "$subshell_depth" -eq 0 ]] && \
               _d2f_heredoc_lexical_state_is_closed "$quote_state" "$cmd_sub_depth" "$arith_sub_depth" "$process_sub_depth"; then
                _out_statements+=("$logical")
                logical=""
                continue
            fi
        fi

        if [[ -z "$current" ]]; then
            current="$logical"
        else
            current+=$'\n'"$logical"
        fi

        if _d2f_heredoc_lexical_state_is_closed "$quote_state" "$cmd_sub_depth" "$arith_sub_depth" "$process_sub_depth"; then
            lexical_was_closed=1
        else
            lexical_was_closed=0
        fi

        _d2f_heredoc_update_lexical_state "$logical" quote_state cmd_sub_depth arith_sub_depth process_sub_depth

        if [[ "$lexical_was_closed" -eq 1 ]]; then
            prior_group_depth="$group_depth"
            prior_function_state="$function_state"
            prior_subshell_depth="$subshell_depth"
            _d2f_heredoc_update_unsupported_group_depth "$logical" group_depth function_state subshell_depth
            if [[ "$prior_group_depth" -eq 0 && "$group_depth" -eq 0 && "$prior_function_state" -eq 0 && "$function_state" -eq 0 && "$prior_subshell_depth" -eq 0 && "$subshell_depth" -eq 0 ]]; then
                _d2f_heredoc_update_shell_depth "$logical" depth
            fi
        fi

        if [[ "$depth" -eq 0 && "$group_depth" -eq 0 && "$function_state" -eq 0 && "$subshell_depth" -eq 0 ]] && \
           _d2f_heredoc_lexical_state_is_closed "$quote_state" "$cmd_sub_depth" "$arith_sub_depth" "$process_sub_depth"; then
            _out_statements+=("$current")
            current=""
        fi
        logical=""
    done <<< "$body"

    if [[ -n "$logical" ]]; then
        if [[ -z "$current" ]]; then
            current="$logical"
        else
            current+=$'\n'"$logical"
        fi
    fi
    [[ -n "$current" ]] && _out_statements+=("$current")
    return 0
}

# Split a small, simple shell context statement into words without executing it.
# Returns non-zero when the text contains shell operators or unbalanced quotes;
# callers then treat the statement as actionable so the existing safety gates
# decide whether to reject it.
_d2f_shell_split_context_words() {
    local input="$1"
    local -n _out_words="$2"
    local i=0 len=${#input} ch next state="none" word=""
    _out_words=()

    while [[ "$i" -lt "$len" ]]; do
        ch="${input:$i:1}"
        next=""
        if [[ $((i + 1)) -lt "$len" ]]; then
            next="${input:$((i + 1)):1}"
        fi

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
                case "$ch" in
                    '"') state="none" ;;
                    "\\")
                        if [[ -n "$next" ]]; then
                            word+="$next"
                            i=$((i + 2))
                            continue
                        fi
                        word+="$ch"
                        ;;
                    *) word+="$ch" ;;
                esac
                i=$((i + 1))
                continue
                ;;
        esac

        case "$ch" in
            [[:space:]])
                if [[ -n "$word" ]]; then
                    _out_words+=("$word")
                    word=""
                fi
                ;;
            "'") state="single" ;;
            '"') state="double" ;;
            "\\")
                if [[ -n "$next" ]]; then
                    word+="$next"
                    i=$((i + 2))
                    continue
                fi
                word+="$ch"
                ;;
            '#')
                if [[ -z "$word" ]]; then
                    break
                fi
                word+="$ch"
                ;;
            ';'|'|'|'&'|'('|')'|'{'|'}'|'<'|'>')
                return 1
                ;;
            *) word+="$ch" ;;
        esac
        i=$((i + 1))
    done

    [[ "$state" == "none" ]] || return 1
    [[ -n "$word" ]] && _out_words+=("$word")
    return 0
}

_d2f_heredoc_assignment_name_is_protected() {
    local name="$1"
    case "$name" in
        PATH|BASH_ENV|ENV) return 0 ;;
    esac
    return 1
}

_d2f_heredoc_word_is_assignment() {
    local word="$1" name
    [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 1
    name="${word%%=*}"
    _d2f_heredoc_assignment_name_is_protected "$name" && return 1
    return 0
}

_d2f_heredoc_set_option_name_is_known() {
    local name="$1"
    case "$name" in
        allexport|braceexpand|emacs|errexit|errtrace|functrace|hashall|histexpand|history|ignoreeof|interactive-comments|keyword|monitor|noclobber|noexec|noglob|nolog|notify|nounset|onecmd|physical|pipefail|posix|privileged|verbose|vi|xtrace)
            return 0 ;;
    esac
    return 1
}

_d2f_heredoc_words_are_set_context() {
    local -n _words_ref="$1"
    local i word flags expect_option_name=0

    [[ "${#_words_ref[@]}" -gt 0 && "${_words_ref[0]}" == "set" ]] || return 1
    [[ "${#_words_ref[@]}" -eq 1 ]] && return 0

    for ((i = 1; i < ${#_words_ref[@]}; i++)); do
        word="${_words_ref[$i]}"

        if [[ "$expect_option_name" -eq 1 ]]; then
            _d2f_heredoc_set_option_name_is_known "$word" || return 1
            expect_option_name=0
            continue
        fi

        case "$word" in
            -o|+o)
                expect_option_name=1
                continue
                ;;
            --|-|+)
                # Treat positional-parameter forms as actionable/reviewable;
                # carrying them as invisible context can hide source text.
                return 1
                ;;
            -[A-Za-z]*|+[A-Za-z]*)
                sign="${word:0:1}"
                flags="${word:1}"
                case "$flags" in
                    *[!A-Za-z]*) return 1 ;;
                esac
                if [[ "$flags" == *o ]]; then
                    expect_option_name=1
                elif [[ "$flags" == *o* ]]; then
                    # Do not try to model ambiguous clusters such as -ox.
                    # Let the normal RUN path and safety gates decide.
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    done

    [[ "$expect_option_name" -eq 0 ]] || return 1
    return 0
}

# Context-only statements carry into later interpreter calls. They are not
# interpreted on their own because they exist to configure later statements.
_d2f_heredoc_statement_is_context() {
    local statement="$1"
    local trimmed word start=0
    local -a words=()
    trimmed="$(_d2f_shell_trim "$statement")"

    [[ -z "$trimmed" || "$trimmed" == \#* ]] && return 1

    _d2f_shell_split_context_words "$trimmed" words || return 1
    [[ "${#words[@]}" -gt 0 ]] || return 1

    if [[ "${words[0]}" == "set" ]]; then
        _d2f_heredoc_words_are_set_context words
        return $?
    fi

    if [[ "${words[0]}" == "export" ]]; then
        [[ "${#words[@]}" -gt 1 ]] || return 1
        start=1
    fi

    for ((i = start; i < ${#words[@]}; i++)); do
        word="${words[$i]}"
        _d2f_heredoc_word_is_assignment "$word" || return 1
    done

    return 0
}

_d2f_append_context_block() {
    local -n _target_ref="$1"
    local addition="$2"

    if [[ -z "$_target_ref" ]]; then
        _target_ref="$addition"
    else
        _target_ref+=$'\n'"$addition"
    fi
}

_d2f_heredoc_review_one_line() {
    local text="$1"
    text="${text//$'\n'/ ; }"
    printf '%s' "$text"
}

# Pending context that never prefixes an actionable statement would otherwise
# vanish. Emit a review record plus a RUN comment so the source text remains
# visible to the user.
_d2f_emit_unused_heredoc_context_review() {
    local context="$1" ir_file="$2" line_num="$3"
    local one_line
    one_line="$(_d2f_heredoc_review_one_line "$context")"

    if declare -f ir_review >/dev/null 2>&1; then
        ir_review "$ir_file" "run-heredoc-context" \
            "RUN line $line_num: heredoc context-only statement had no later actionable statement; review manually: $one_line"
    fi

    if declare -f ir_hook >/dev/null 2>&1; then
        ir_hook "$ir_file" "run" "# RUN: heredoc context-only statement not applied; review manually: $one_line"
    else
        printf '# RUN: heredoc context-only statement not applied; review manually: %s\n' "$one_line" >> "$ir_file"
    fi
}
# Process a Dockerfile heredoc RUN body statement by statement. Each actionable
# statement re-enters _parse_run with a recursion guard so the original safety
# gates, interpreter, event parsing, review records, skip rules, and extractors
# stay on their existing paths.
_parse_run_heredoc_per_statement() {
    local run_body="$1" ir_file="$2" line_num="$3"
    local -a statements=()
    local statement trimmed context="" pending_context="" parse_body subset_issue safety_issue

    if _d2f_run_body_has_shell_heredoc_operator "$run_body"; then
        D2F_RUN_HEREDOC_STATEMENT_PARSE=1 _parse_run "RUN $run_body" "$ir_file" "$line_num"
        return 0
    fi

    _d2f_split_heredoc_run_statements "$run_body" statements

    for statement in "${statements[@]}"; do
        trimmed="$(_d2f_shell_trim "$statement")"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

        if _d2f_heredoc_statement_is_context "$statement"; then
            _d2f_append_context_block context "$statement"
            _d2f_append_context_block pending_context "$statement"
            continue
        fi

        subset_issue="$(_run_body_safe_subset_issue "$statement" "${shell_kind:-sh}" || true)"
        if [[ -n "$subset_issue" ]]; then
            D2F_RUN_HEREDOC_STATEMENT_PARSE=1 _parse_run "RUN $statement" "$ir_file" "$line_num"
            continue
        fi

        safety_issue="$(_run_body_safety_issue "$statement" || true)"
        if [[ -n "$safety_issue" ]]; then
            D2F_RUN_HEREDOC_STATEMENT_PARSE=1 _parse_run "RUN $statement" "$ir_file" "$line_num"
            continue
        fi

        parse_body="$statement"
        if [[ -n "$context" ]]; then
            parse_body="$context"$'\n'"$statement"
            pending_context=""
        fi

        D2F_RUN_HEREDOC_STATEMENT_PARSE=1 _parse_run "RUN $parse_body" "$ir_file" "$line_num"
    done

    if [[ -n "$pending_context" ]]; then
        _d2f_emit_unused_heredoc_context_review "$pending_context" "$ir_file" "$line_num"
    fi

    return 0
}
