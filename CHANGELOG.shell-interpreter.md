# dock2flox shell-interpreter update

This bundle adds interpreter-assisted Dockerfile RUN parsing.

## Changed

- Added `lib/run_shell_interpreter.sh`, a stubbed Bash interpreter for RUN bodies.
- `bin/dock2flox` now sources the interpreter before the Dockerfile parser.
- `lib/parser_dockerfile.sh` now prefers interpreter events and falls back to the prior conservative splitter.
- Added tests for variable-expanded package lists, quoted separators, loop-driven corepack enables, `uname -m` architecture branches, heredoc RUN bodies, modelled `[[ -f /etc/... ]]` OS probes, and uncertain-predicate fallback avoidance.
- Updated README with the interpreter behavior and remaining limits.

## Validation

`tests/run_tests.sh` passes 40 tests.

## Second pass refinements

- Dockerfile preprocessing now normalizes pure `RUN <<EOF` heredocs into one interpreted RUN body.
- The Bash interpreter models common `uname`, `id`, and `whoami` probes without consulting the host.
- Common Bash `[[ -f /etc/... ]]` distro checks are normalized into the stubbed `test` command.
- When interpretation records uncertain predicates, dock2flox emits a review hook instead of falling back to raw text splitting that can pick up inactive branches.
