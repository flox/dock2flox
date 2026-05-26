# dock2flox env-command safety hardening

- Command-position variable expansions such as `$CMD`, `${CMD}`, `env $CMD`,
  and `sudo $CMD` are now treated as review-only before Bash interpretation.
- This prevents Dockerfile `ENV`/`ARG` values that expand to slash-addressed
  host binaries or scripts from mutating the analyzer host.
- Variables remain supported as arguments to modeled package-manager stubs, for
  example `apt-get install -y $PKGS`.
- Added regressions for ENV/ARG command variables and preserved modeled install
  argument expansion.
