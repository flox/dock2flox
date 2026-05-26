# dock2flox robustness fixes

Implemented safety and correctness fixes for the interpreter-assisted analyzer:

- Rejects RUN interpretation when unquoted shell redirection or process-substitution syntax appears, then falls back to conservative parsing without running the body.
- Runs interpreted RUN bodies from an isolated scratch working directory as a second safety layer for relative writes.
- Models `command -v` for the detected final-stage package manager so Debian/Ubuntu-style images do not take Alpine branches, and vice versa.
- Treats unknown `command -v` and unknown file-test predicates as uncertain, then falls back to conservative parsing instead of using host state.
- Stubs `test` and `[` for common string comparisons and known OS marker files.
- Moves known-installer detection from raw RUN substring scanning to event/token-based detection from active `curl` and `wget` invocations.
- Records event lines atomically to avoid interleaved event records from shell pipelines.
- Treats `eval`, `exec`, `source`, and `.` as dynamic shell constructs and emits a commented hook instead of fallback-parsing quoted shell text as executable installer syntax.
- Adds regression fixtures for host-write blocking, modeled `command -v` control flow, inert quoted installer URLs, dynamic eval, and active curl/wget installer detection.

Validation:

```text
Results: 35 passed, 0 failed, 0 skipped
```
