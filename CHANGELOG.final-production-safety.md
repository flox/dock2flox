# Final production safety hardening

- Added a fail-closed RUN safety boundary for path-addressed command words.
  Commands such as `/usr/bin/touch`, `/bin/sh`, `/usr/bin/env`, `./install.sh`,
  `../script`, and `scripts/install.sh` are never executed on the analyzer host.
- Path-addressed commands now emit `REVIEW[run-path]` and active extraction for
  that RUN is skipped unless the path is an explicitly modeled safe stub such as
  `./mvnw` or `./gradlew`.
- Added static rejection for obvious non-terminating shell loops before invoking
  Bash: `while true`, `while :`, `until false`, and `for (( ; ; ))`.
- Added fast and slow test modes. The default test run skips the dynamic timeout
  fixture; `tests/run_tests.sh --slow` runs it.
- Added per-test timing output via `DOCK2FLOX_TEST_TIMING=1`.
- Added regression coverage for absolute-path host mutation, local script host
  mutation, `/usr/bin/env bash -c ...`, normal modeled package installs,
  process-group timeout cleanup, and the prior platform/ENV/SHELL/idempotency
  blockers.
