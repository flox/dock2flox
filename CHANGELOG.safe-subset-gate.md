# Safe-subset gate production hardening

- Added a conservative safe-subset gate before interpreted Dockerfile `RUN` bodies reach host Bash.
- `time`, `!`, `coproc`, brace groups, subshell groups, shell functions, wrapper dispatch, non-modelled command substitutions, redirections, process substitutions, `eval`, `source`, and `exec` are now review-only.
- Kept the prior path-addressed command, command-position variable, wrapper, and function protections as defense-in-depth.
- Added regression coverage for host-mutation bypasses through `time`, `!`, `coproc`, and brace groups.
- Preserved variable expansion as arguments to modeled safe commands, platform/ENV/SHELL/predicate regressions, original BRIEF gap tests, and deterministic fast/slow test modes.
