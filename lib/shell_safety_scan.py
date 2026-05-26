#!/usr/bin/env python3
"""Conservative safety scanner for Dockerfile RUN bodies.

It does not try to be a full shell parser. It catches command-position tokens that
would address a file path directly (for example /usr/bin/touch or ./install.sh)
before the interpreter can hand them to the host shell. Output is a single tab
separated record when the caller should fail closed:

    PATH<TAB><token>
    VARCMD<TAB><token>
    LOOP<TAB><description>
    FUNCTION<TAB><description>

Exit status 0 means no issue detected; 2 means review-only issue detected.
"""
from __future__ import annotations

import re
import shlex
import sys
from typing import Iterable

# Path commands that are explicitly modeled as safe stubs by dock2flox. They are
# never executed; they only emit lifecycle review/hook records.
SAFE_PATH_COMMANDS = {"./mvnw", "./gradlew"}
SEPARATORS = {";", "&", "&&", "|", "||", "(", ")"}
COMMAND_START_KEYWORDS = {"then", "do", "else", "elif"}
PREFIX_COMMANDS = {"sudo", "doas", "env", "command", "builtin", "xargs"}
SHELL_COMMANDS = {"sh", "bash"}
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", re.S)

LOOP_PATTERNS = [
    (re.compile(r"(^|[;&|])\s*while\s+true\s*;?\s*do\b", re.S), "while true loop"),
    (re.compile(r"(^|[;&|])\s*while\s+:\s*;?\s*do\b", re.S), "while : loop"),
    (re.compile(r"(^|[;&|])\s*until\s+false\s*;?\s*do\b", re.S), "until false loop"),
    (re.compile(r"(^|[;&|])\s*for\s*\(\(\s*;\s*;\s*\)\)\s*;?\s*do\b", re.S), "for (( ; ; )) loop"),
]

FUNCTION_PATTERNS = [
    (re.compile(r"(^|[;&|])\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{", re.S), "shell function definition"),
    (re.compile(r"(^|[;&|])\s*function\s+[A-Za-z_][A-Za-z0-9_]*(\s*\(\))?\s*\{", re.S), "shell function definition"),
]


def tokenize(body: str) -> list[str]:
    """Small shell lexer for safety scanning.

    It preserves enough command-position structure for fail-closed safety checks
    without invoking shlex's punctuation handling, which can be slow on URL-like
    strings such as https://example.
    """
    tokens: list[str] = []
    buf: list[str] = []
    state = "none"
    i = 0
    n = len(body)

    def flush() -> None:
        if buf:
            tokens.append("".join(buf))
            buf.clear()

    while i < n:
        ch = body[i]
        if state == "single":
            if ch == "'":
                state = "none"
            else:
                buf.append(ch)
            i += 1
            continue
        if state == "double":
            if ch == "\\" and i + 1 < n:
                buf.append(body[i + 1])
                i += 2
                continue
            if ch == '"':
                state = "none"
            else:
                buf.append(ch)
            i += 1
            continue

        if ch == "'":
            state = "single"
            i += 1
            continue
        if ch == '"':
            state = "double"
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            buf.append(body[i + 1])
            i += 2
            continue
        if ch.isspace():
            flush()
            i += 1
            continue
        if ch in ";()":
            flush()
            tokens.append(ch)
            i += 1
            continue
        if ch in "&|":
            flush()
            if i + 1 < n and body[i + 1] == ch:
                tokens.append(ch + ch)
                i += 2
            else:
                tokens.append(ch)
                i += 1
            continue
        buf.append(ch)
        i += 1
    flush()
    return tokens


def is_path_command(token: str) -> bool:
    if token in SAFE_PATH_COMMANDS:
        return False
    if "://" in token:
        return False
    return "/" in token


def is_variable_command(token: str) -> bool:
    # Fail closed on command-position variable expansion. Bash can expand these
    # to /usr/bin/foo or ./script after the static scanner has run, bypassing
    # PATH restrictions and executing analyzer-host files. Argument-position
    # variables are still safe for modeled stubs such as `apt-get install $PKGS`.
    return token.startswith("$") or token.startswith("${")


def scan_inner_script(script: str) -> tuple[str, str] | None:
    # Do not recursively report ordinary package-manager commands, but do catch
    # path-addressed commands or obvious infinite loops inside sh -c/bash -c.
    return scan(script)


def skip_env_prefix(tokens: list[str], i: int) -> int:
    # tokens[i] is env. Skip env flags and assignments to find the command env
    # would execute. This is intentionally conservative; unknown flags that take
    # values are skipped as a pair.
    i += 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            return i + 1
        if ASSIGNMENT_RE.match(tok):
            i += 1
            continue
        if tok in {"-i", "--ignore-environment", "-0"}:
            i += 1
            continue
        if tok.startswith("-"):
            # Most env flags either stand alone or take one operand; skipping one
            # extra value is safer than treating it as a command.
            i += 1
            if i < len(tokens) and tokens[i] not in SEPARATORS:
                i += 1
            continue
        break
    return i


def find_c_option_script(tokens: list[str], i: int) -> str | None:
    # tokens[i] is sh/bash. Find the argument following -c.
    i += 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-c":
            if i + 1 < len(tokens):
                return tokens[i + 1]
            return ""
        if tok in SEPARATORS:
            return None
        i += 1
    return None


def skip_command_prefix(tokens: list[str], i: int) -> int | None:
    # tokens[i] is command. `command -v foo` is a probe and safe to model;
    # `command /path` or `command $CMD` would dispatch a command word.
    i += 1
    while i < len(tokens):
        tok = tokens[i]
        if tok in SEPARATORS:
            return None
        if tok == "--":
            return i + 1
        if tok in {"-v", "-V", "-p"}:
            return None
        if tok.startswith("-"):
            i += 1
            continue
        return i
    return None


def skip_xargs_prefix(tokens: list[str], i: int) -> int | None:
    # tokens[i] is xargs. If xargs has an explicit utility operand, that operand
    # is a command word and must be checked. Without an explicit utility, the
    # analyzer stub does not execute stdin-derived commands.
    i += 1
    while i < len(tokens):
        tok = tokens[i]
        if tok in SEPARATORS:
            return None
        if tok == "--":
            return i + 1 if i + 1 < len(tokens) else None
        if tok in {"-0", "-r", "--no-run-if-empty", "-t", "-p"}:
            i += 1
            continue
        if tok in {"-n", "-P", "-I", "--max-args", "--max-procs", "--replace"}:
            i += 2
            continue
        if tok.startswith("-"):
            # Unknown xargs option: be conservative and stop treating later
            # tokens as safe operands.
            return None
        return i
    return None


def inspect_dispatch_token(tokens: list[str], j: int) -> tuple[str, str] | None:
    if j is None or j >= len(tokens):
        return None
    nxt = tokens[j]
    if is_variable_command(nxt):
        return ("VARCMD", nxt)
    if is_path_command(nxt):
        return ("PATH", nxt)
    if nxt in SHELL_COMMANDS:
        script = find_c_option_script(tokens, j)
        if script:
            inner = scan_inner_script(script)
            if inner is not None:
                return inner
    return None


def scan(body: str) -> tuple[str, str] | None:
    for pattern, desc in LOOP_PATTERNS:
        if pattern.search(body):
            return ("LOOP", desc)

    for pattern, desc in FUNCTION_PATTERNS:
        if pattern.search(body):
            return ("FUNCTION", desc)

    tokens = tokenize(body)
    if not tokens:
        return None

    command_expected = True
    i = 0
    while i < len(tokens):
        tok = tokens[i]

        if tok in SEPARATORS:
            command_expected = True
            i += 1
            continue

        if tok in COMMAND_START_KEYWORDS:
            command_expected = True
            i += 1
            continue

        if tok in {"if", "while", "until", "case", "for", "select", "function"}:
            command_expected = True
            i += 1
            continue

        if command_expected and ASSIGNMENT_RE.match(tok):
            i += 1
            continue

        if command_expected:
            if is_variable_command(tok):
                return ("VARCMD", tok)

            if is_path_command(tok):
                return ("PATH", tok)

            if tok in PREFIX_COMMANDS:
                if tok == "env":
                    j = skip_env_prefix(tokens, i)
                elif tok in {"sudo", "doas"}:
                    j = i + 1
                elif tok == "command":
                    j = skip_command_prefix(tokens, i)
                elif tok == "builtin":
                    # Only `builtin command ...` dispatches an arbitrary command
                    # word through this path. Other builtins are inert in the
                    # analyzer.
                    if i + 1 < len(tokens) and tokens[i + 1] == "command":
                        j = skip_command_prefix(tokens, i + 1)
                    else:
                        j = None
                elif tok == "xargs":
                    j = skip_xargs_prefix(tokens, i)
                else:
                    j = None
                issue = inspect_dispatch_token(tokens, j)
                if issue is not None:
                    return issue
                command_expected = False
                i += 1
                continue

            if tok in SHELL_COMMANDS:
                script = find_c_option_script(tokens, i)
                if script:
                    inner = scan_inner_script(script)
                    if inner is not None:
                        return inner

            command_expected = False

        i += 1

    return None


def main() -> int:
    body = sys.stdin.read()
    issue = scan(body)
    if issue is None:
        return 0
    print(f"{issue[0]}\t{issue[1]}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
