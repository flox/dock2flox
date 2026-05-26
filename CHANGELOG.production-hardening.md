# Production hardening pass

This pass addresses blocking correctness feedback from adversarial Dockerfile and
Compose-style migration cases.

## Correctness fixes

- `FROM --platform=...` now drives the `uname -m` model used by the RUN
  interpreter. For example, `--platform=linux/arm64` models `uname -m` as
  `aarch64`, so amd64-only branches are not emitted as active packages.
- Unknown shell predicates are now fail-closed. If a RUN contains an unmodelled
  predicate, dock2flox emits a `REVIEW[run-predicate]` note and skips
  branch-specific package extraction instead of choosing the false/else branch.
- Docker `SHELL` semantics now gate active RUN extraction. Bash-only syntax under
  `/bin/sh -c` is not analyzed as active; Bash syntax is analyzed only when the
  Dockerfile sets a Bash shell.
- Unsupported/custom shells are preserved for review and not mined for active
  packages.
- Default write mode is now idempotent: writing the same manifest twice is a
  successful no-op reported as `Unchanged:`. Differing existing manifests still
  require `--force` or an interactive confirmation.

## Regression coverage

Added adversarial fixtures for:

- arm64 platform branch selection;
- unmodelled file predicates with then/else package branches;
- `/bin/sh` rejecting Bash arrays;
- explicit Bash `SHELL` accepting Bash arrays;
- idempotent default writes.

## Production stance

The tool is now stricter about correctness: when Dockerfile state cannot be
modelled safely, it preserves the original intent through review comments rather
than emitting a potentially wrong active Flox install entry.
