# Function Safety Hardening

- Treat Dockerfile RUN shell function definitions as review-only instead of
  invoking host Bash on their bodies.
- Emit `REVIEW[run-function]` and preserve the original RUN as a review hook.
- Add regression fixtures proving both literal path commands and ENV-expanded
  command words hidden in functions do not mutate the analyzer host.
- Disable test prewarm by default so the fast test suite is deterministic; use
  `DOCK2FLOX_TEST_PREWARM=1` to opt in.

- Added a compact `release` test section and made `tests/run_tests.sh` run it
  by default. The larger legacy sections remain available through
  `tests/run_tests_split.py --section ...` for local investigation.
