# dock2flox production readiness hardening

This pass fixes the final blocker class from the production review.

## Correctness fixes

- Dockerfile `ENV` state is now exported into interpreted later `RUN` bodies, matching Docker's rule that `ENV` persists across subsequent build steps.
- `ENV` expansion now works for package lists and conditionals such as `ENV PKGS="curl jq"` followed by `RUN apt-get install -y $PKGS`.
- `FROM --platform=$TARGETPLATFORM` and other unresolved platform expressions no longer default silently to `x86_64` for `uname -m` modelling. Architecture-dependent `RUN` bodies fail closed and emit `REVIEW[run-platform]`.
- Summary counters now use a `_grep_count` helper instead of `grep -c ... || printf 0`, eliminating noisy arithmetic warnings on zero matches.
- Default write mode remains idempotent for unchanged output and now has a regression check that verifies no warning/error text is emitted on the second identical write.

## Test-harness fixes

- The test runner now executes fixtures through a Python harness that starts each render in its own process group.
- Timed-out fixtures terminate the whole process group, including child and grandchild shell processes.
- Test diagnostics include the command that timed out or failed.
- The harness uses temp files for stdout/stderr capture to avoid pipe backpressure and descriptor hangs.
- Docker JSON array parsing uses a fast shell fallback for common arrays, avoiding repeated Python startup during Dockerfile parsing.
- Static simple `RUN` bodies use the conservative parser fast path; dynamic shell constructs still go through the interpreter.

## Regression coverage

Added or preserved tests for:

- `ENV PKGS="curl jq"` followed by `RUN apt-get install -y $PKGS`.
- `ENV INSTALL=true` followed by a conditional `RUN`.
- second identical default write with no stderr arithmetic warning.
- `FROM --platform=$TARGETPLATFORM` with architecture probes emits review markers and no branch-specific packages.
- bounded timeout behavior for infinite shell loops.

## Validation

`tests/run_tests.sh` completed successfully in this environment:

```text
Results: 90 passed, 0 failed, 0 skipped
```
