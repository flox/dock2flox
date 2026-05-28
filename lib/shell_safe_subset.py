#!/usr/bin/env python3
"""Conservative RUN-body safety classifier for dock2flox.

This is intentionally not a full Bash interpreter. It decides whether a RUN body
is safe enough to pass to the stubbed Bash interpreter. The default is to reject
shell constructs that can introduce deferred command execution or bypass the
stubbed command allowlist. Rejected bodies are preserved as REVIEW notes by the
caller.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass

DANGEROUS_ASSIGNMENTS = {"PATH", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"}
SAFE_PATH_COMMANDS = {"./mvnw", "./gradlew"}
CONTROL_WORDS = {
    "if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac", "do", "done", "in",
    "[[", "]]",
}
REVIEW_WRAPPERS = {"sudo", "doas", "builtin"}
REVIEW_COMMANDS = {"eval", "source", "."}
UNSUPPORTED_CONTROL = {"time", "coproc", "!"}
UNSAFE_BUILTINS = {"kill", "mapfile", "typeset", "enable", "hash", "trap", "alias", "unalias"}
MODELED_COMMANDS = {
    # Package managers
    "apt-get", "apt", "apk", "yum", "dnf", "add-apt-repository", "apt-key",
    "dpkg", "gpg", "yum-config-manager", "rpm",
    # Language package managers / runtimes
    "pip", "pip3", "uv", "npm", "npx", "corepack", "python", "python3",
    "virtualenv", "poetry", "pdm", "pipenv", "node", "pnpm", "yarn", "ruby", "bundle",
    "bundler", "gem", "php", "cargo", "rustup", "go", "composer", "java",
    "mvn", "gradle", "./mvnw", "./gradlew", "make", "cmake",
    # Downloaders
    "curl", "wget",
    # Shells / interpreters
    "sh", "bash",
    # System probes
    "uname", "id", "whoami", "test", "[", "command",
    # File operations (common Dockerfile cleanup/setup — no host risk in interpreter)
    "rm", "cp", "mv", "ln", "touch", "chmod", "chown", "chgrp", "install",
    "tar", "unzip", "gzip", "gunzip", "xz", "bzip2", "bunzip2",
    # Text / stream utilities
    "cat", "sed", "awk", "grep", "egrep", "fgrep", "head", "tail", "wc",
    "sort", "cut", "tr", "tee", "echo", "printf", "yes",
    # File info
    "ls", "pwd", "basename", "dirname", "find", "which", "file", "stat",
    "readlink", "realpath",
    # Checksums
    "sha256sum", "sha512sum", "md5sum", "sha1sum",
    # User management (common in Dockerfiles, no-op in interpreter)
    "groupadd", "useradd", "adduser", "addgroup", "usermod",
    # System config (common in Dockerfiles, no-op in interpreter)
    "ldconfig", "update-ca-certificates", "locale-gen", "update-alternatives",
    "dpkg-reconfigure", "sync",
    # Directory operations
    "mkdir", "rmdir", "mktemp",
    # Common builtins that are safe in interpreter context
    "export", "unset", "cd", "pushd", "popd", "set", "shopt", "shift",
    "break", "continue", "return", "declare", "readonly", "local",
    "read", "exec",
    # Wrappers (interpreter controls dispatch)
    "env", "xargs",
    # Control / no-ops
    "true", "false", ":", "sleep", "date", "noop",
}
SEPARATORS = {";", "&&", "||", "|", "\n"}


@dataclass
class Token:
    kind: str  # word/op
    value: str
    pos: int


def _review(kind: str, reason: str) -> int:
    print(f"REVIEW\t{kind}\t{reason}")
    return 1


def _is_name_char(ch: str) -> bool:
    return ch.isalnum() or ch == "_"


def _scan_dollar_paren(text: str, start: int) -> tuple[str, int]:
    # start points at '$' and text[start + 1] == '('. Return full substitution.
    i = start + 2
    depth = 1
    quote: str | None = None
    out = ["$("]
    while i < len(text):
        ch = text[i]
        out.append(ch)
        if quote:
            if ch == "\\":
                if i + 1 < len(text):
                    out.append(text[i + 1])
                    i += 2
                    continue
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
        elif ch == "(" and i > 0 and text[i - 1] == "$":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return "".join(out), i + 1
        i += 1
    return "".join(out), i


def _scan_array_assignment(text: str, start: int) -> tuple[str, int] | None:
    m = re.match(r"[A-Za-z_][A-Za-z0-9_]*\s*=\s*\(", text[start:])
    if not m:
        return None
    i = start + m.end()
    depth = 1
    quote: str | None = None
    out = [text[start:i]]
    while i < len(text):
        ch = text[i]
        out.append(ch)
        if quote:
            if ch == "\\":
                if i + 1 < len(text):
                    out.append(text[i + 1])
                    i += 2
                    continue
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return "".join(out), i + 1
        i += 1
    return "".join(out), i


def tokenize(text: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            if ch == "\n":
                tokens.append(Token("op", "\n", i))
            i += 1
            continue
        if text.startswith("&&", i) or text.startswith("||", i) or text.startswith(";;", i):
            tokens.append(Token("op", text[i:i+2], i))
            i += 2
            continue
        if ch in ";|{}":
            tokens.append(Token("op", ch, i))
            i += 1
            continue
        # Treat standalone parens as operators, but leave case patterns like x86_64)
        # and array assignments as words.
        arr = _scan_array_assignment(text, i)
        if arr:
            value, i = arr
            tokens.append(Token("word", value, i - len(value)))
            continue
        if ch in "()":
            tokens.append(Token("op", ch, i))
            i += 1
            continue
        start = i
        out: list[str] = []
        quote: str | None = None
        while i < n:
            ch = text[i]
            if quote:
                out.append(ch)
                if ch == "\\":
                    if i + 1 < n:
                        out.append(text[i + 1])
                        i += 2
                        continue
                elif ch == quote:
                    quote = None
                i += 1
                continue
            if ch.isspace() or ch in ";|{}()":
                break
            if text.startswith("&&", i) or text.startswith("||", i) or text.startswith(";;", i):
                break
            if ch in "'\"":
                quote = ch
                out.append(ch)
                i += 1
                continue
            if ch == "`":
                # Backticks can run arbitrary host commands inside Bash.
                out.append(ch)
                i += 1
                while i < n:
                    out.append(text[i])
                    if text[i] == "`":
                        i += 1
                        break
                    if text[i] == "\\" and i + 1 < n:
                        out.append(text[i + 1])
                        i += 2
                    else:
                        i += 1
                continue
            if ch == "$" and i + 1 < n and text[i + 1] == "(":
                subst, i = _scan_dollar_paren(text, i)
                out.append(subst)
                continue
            out.append(ch)
            i += 1
        if out:
            tokens.append(Token("word", "".join(out), start))
        else:
            i += 1
    return tokens


def _strip_quotes(value: str) -> str:
    if (value.startswith("'") and value.endswith("'")) or (value.startswith('"') and value.endswith('"')):
        return value[1:-1]
    return value


def _contains_backticks(text: str) -> bool:
    quote: str | None = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
        elif ch == "`":
            return True
        i += 1
    return False


def _unquoted_redirection_or_process_subst(tokens: list[Token]) -> bool:
    for tok in tokens:
        if tok.kind == "op" and tok.value in {"<", ">"}:
            return True
        if tok.kind == "word" and ("<(" in tok.value or ">(" in tok.value):
            return True
    return False


def _command_substitutions(text: str) -> list[str]:
    subs: list[str] = []
    i = 0
    quote: str | None = None
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
            # Command substitutions still execute inside double quotes.
            if quote != "'" and ch == "$" and i + 1 < len(text) and text[i + 1] == "(":
                subst, i = _scan_dollar_paren(text, i)
                subs.append(subst)
                continue
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            i += 1
            continue
        if ch == "$" and i + 1 < len(text) and text[i + 1] == "(":
            subst, i = _scan_dollar_paren(text, i)
            subs.append(subst)
            continue
        i += 1
    return subs


def _safe_command_substitution(subst: str) -> bool:
    inner = subst[2:-1].strip() if subst.startswith("$(") and subst.endswith(")") else ""
    inner = re.sub(r"\s+", " ", inner)
    return inner in {"uname -m", "uname --machine", "uname -s", "uname", "id -u", "id -g", "whoami"}


def _is_assignment(word: str) -> tuple[str, str] | None:
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", word, re.S)
    if not m:
        return None
    return m.group(1), m.group(2)


def _is_command_position_variable(word: str) -> bool:
    w = word.strip()
    while w.startswith(("'", '"')) and len(w) > 1:
        w = w[1:]
    return w.startswith("$") or w.startswith("${")


def _is_path_command(word: str) -> bool:
    w = _strip_quotes(word)
    if w in SAFE_PATH_COMMANDS:
        return False
    if "://" in w:
        return False
    return "/" in w


def classify(text: str, shell_kind: str = "sh") -> tuple[bool, str, str]:
    if _contains_backticks(text):
        return False, "run-unsupported", "backtick command substitution is review-only"

    # Function definitions are deferred execution; reject before Bash runs.
    compact = " " + text.replace("\n", " ; ") + " "
    if re.search(r"[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{", compact) or re.search(r"(^|[\s;&|])function\s+[A-Za-z_][A-Za-z0-9_]*(\s*\(\))?\s*\{", compact):
        return False, "run-function", "shell function definitions are review-only"

    for subst in _command_substitutions(text):
        if not _safe_command_substitution(subst):
            return False, "run-unsupported", f"unsupported command substitution: {subst[:80]}"

    tokens = tokenize(text)

    # Braced command groups and coprocess/time/negation constructs have too many
    # command-introducing forms to safely execute through host Bash.
    for tok in tokens:
        if tok.kind == "op" and tok.value in {"{", "}"}:
            return False, "run-unsupported", "brace command group is review-only"
        if tok.kind == "op" and tok.value == "(":
            # Bash array assignments are tokenized as words by tokenize(); a raw
            # paren operator means subshell/group syntax, not a safe assignment.
            return False, "run-unsupported", "subshell/group syntax is review-only"

    if _unquoted_redirection_or_process_subst(tokens):
        return False, "run-unsupported", "redirection or process substitution is review-only"

    expect_cmd = True
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok.kind == "op":
            if tok.value in SEPARATORS or tok.value in {";;", "("}:
                expect_cmd = True
            i += 1
            continue

        word = tok.value
        bare = _strip_quotes(word)

        # Assignment words at command position are safe unless they alter the
        # command lookup/execution environment. Skip them and keep command-pos.
        if expect_cmd:
            assign = _is_assignment(bare)
            while assign is not None and i + 1 < len(tokens):
                name, _value = assign
                if name in DANGEROUS_ASSIGNMENTS:
                    return False, "run-unsupported", f"command environment assignment {name}= is review-only"
                i += 1
                tok = tokens[i]
                if tok.kind != "word":
                    break
                word = tok.value
                bare = _strip_quotes(word)
                assign = _is_assignment(bare)
            if tok.kind != "word":
                continue

            if bare in CONTROL_WORDS:
                expect_cmd = True if bare in {"then", "else", "do"} else False
                i += 1
                continue

            if bare in UNSUPPORTED_CONTROL:
                return False, "run-unsupported", f"unsupported shell control form: {bare}"

            if bare in REVIEW_COMMANDS:
                return False, "run-unsupported", f"unsafe shell builtin is review-only: {bare}"

            if bare in UNSAFE_BUILTINS:
                return False, "run-unsupported", f"unmodelled Bash builtin is review-only: {bare}"

            if bare in REVIEW_WRAPPERS:
                return False, "run-path", f"wrapper command is review-only: {bare}"

            if bare == "command":
                # `command -v name` is needed for common Dockerfile probes and
                # is modeled by the interpreter; all other command dispatch is
                # review-only because it can bypass shell functions/stubs.
                nxt = tokens[i + 1].value if i + 1 < len(tokens) and tokens[i + 1].kind == "word" else ""
                nxt2 = tokens[i + 2].value if i + 2 < len(tokens) and tokens[i + 2].kind == "word" else ""
                if nxt in {"-v", "-V"} and nxt2 and not _is_path_command(nxt2) and not _is_command_position_variable(nxt2):
                    expect_cmd = False
                    i += 1
                    continue
                return False, "run-path", "command wrapper dispatch is review-only"

            if bare in {"sh", "bash"}:
                # Piped installer sinks like `curl ... | sh -s -- -y` are stubs.
                # Inline shell execution is review-only.
                if i + 1 < len(tokens) and tokens[i + 1].kind == "word" and tokens[i + 1].value == "-c":
                    return False, "run-path", f"{bare} -c wrapper is review-only"
                expect_cmd = False
                i += 1
                continue

            if _is_command_position_variable(bare):
                return False, "run-path", f"command-position variable expansion: {bare}"

            if _is_path_command(bare):
                return False, "run-path", f"path-addressed command: {bare}"

            if bare not in MODELED_COMMANDS:
                return False, "run-unsupported", f"unmodelled command word is review-only: {bare}"

            expect_cmd = False
        i += 1

    return True, "", ""


def main() -> int:
    shell_kind = sys.argv[1] if len(sys.argv) > 1 else "sh"
    text = sys.stdin.read()
    ok, kind, reason = classify(text, shell_kind)
    if ok:
        print("OK")
        return 0
    return _review(kind, reason)


if __name__ == "__main__":
    raise SystemExit(main())
