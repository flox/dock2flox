# Test harness determinism fixes

This change makes the bundled regression suite bounded and deterministic.

- `tests/run_tests.sh` writes dry-run output directly to cache files instead of
  capturing it with Bash command substitution. This avoids pipe/file-descriptor
  hangs if a child process regression keeps stdout open.
- Each fixture render is wrapped in a configurable outer timeout via
  `DOCK2FLOX_TEST_TIMEOUT` (default: `30s`).
- The RUN shell interpreter timeout is configurable via
  `DOCK2FLOX_RUN_TIMEOUT` (default: `5s` in normal use, `1s` in tests).
- Interpreter timeouts use `timeout --kill-after=1s` so child Bash processes are
  cleaned up promptly.
- Test failures now print the first stderr lines from the failed render to make
  timeout or parser regressions easier to diagnose.

These changes do not alter generated manifests in normal successful cases; they
make regressions fail quickly instead of leaving the suite running indefinitely.
- Added `tests/fixtures/Dockerfile.run-timeout` to ensure an infinite shell loop
  is bounded by the interpreter timeout and the suite continues to later RUN
  instructions.
