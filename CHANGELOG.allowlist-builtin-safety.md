# Allowlist Builtin Safety Hardening

- RUN interpretation now rejects command-position words that are not in the modeled stub allowlist.
- Unmodelled Bash builtins that can mutate host state, signal host processes, or alter interpreter state are review-only, including kill, printf, read, mapfile, declare, typeset, readonly, export, unset, cd, pushd, popd, shopt, set, enable, hash, trap, alias, and unalias.
- Added a regression that spawns a host sleep process, analyzes `RUN kill -TERM <pid>`, and verifies the process remains alive while a REVIEW note is emitted.
