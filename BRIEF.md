# dock2flox: Handoff Brief

Bash tool that converts Dockerfiles → Flox manifest.toml. Read FLOX.md for
Flox conventions, GUIDANCE.md Playbook 3 for the "why", README.md for usage.

## Current state: ~90% automated
- `bin/dock2flox --dry-run examples/Dockerfile` shows what works
- `tests/run_tests.sh` passes 12 tests (run it after any change)
- Three audits done; all critical/moderate bugs fixed

## The remaining 10% gap (close these)
1. Conflict detection: corepack vs nodejs both provide bin/corepack — tool
   should warn or auto-set priority when known conflicts exist
2. POETRY_HOME=/usr/local is container-specific; should become $FLOX_ENV
3. `corepack enable yarn` in [hook] is redundant if yarn-berry is in [install]
4. -r requirements.txt / pyproject.toml → emit `uv sync` or `uv pip install -r`
   as a real hook command, not a comment
5. Multi-installer RUN blocks: only first pattern matched; detect all

## Standards to enforce
- IR uses \x1f delimiter with _ir_encode/_ir_decode — never raw pipes
- TOML strings go through _toml_escape(); multi-line uses '''
- All greps on IR use `|| true` to survive set -euo pipefail
- No `((var++))` — use `var=$((var + 1))`
- Functions use `return` not `exit`
- Data-driven: new mappings go in data/*.map files, not code
