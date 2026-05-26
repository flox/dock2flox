#!/usr/bin/env bash
# dock2flox test runner. Default mode runs a bounded production-regression
# section; slow mode exercises the intentional dynamic timeout fixture.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONUNBUFFERED=1

if [[ "${1:-}" == "--slow" || "${DOCK2FLOX_TEST_SLOW:-0}" == "1" ]]; then
    [[ "${1:-}" == "--slow" ]] && shift
    exec python3 "$SCRIPT_DIR/run_tests_split.py" --section slow "$@"
fi

exec python3 "$SCRIPT_DIR/run_tests_split.py" --section release "$@"
