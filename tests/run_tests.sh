#!/usr/bin/env bash
# dock2flox test runner
# Runs dock2flox against fixture files and validates output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCK2FLOX="$ROOT_DIR/bin/dock2flox"
FIXTURES="$SCRIPT_DIR/fixtures"
EXPECTED="$FIXTURES/expected"

# Colors (if terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

pass=0
fail=0
skip=0

run_test() {
    local name="$1"
    local input="$2"
    local expected="${3:-}"
    local extra_args="${4:-}"

    printf "  %-40s" "$name"

    # Run dock2flox
    local actual
    actual=$(DOCK2FLOX_SERVICES=container "$DOCK2FLOX" --dry-run $extra_args "$input" 2>/dev/null) || {
        printf "${RED}FAIL${NC} (exit code $?)\n"
        fail=$((fail + 1))
        return 0
    }

    # If expected file exists, compare
    if [[ -n "$expected" && -f "$expected" ]]; then
        local expected_content
        expected_content=$(cat "$expected")
        if [[ "$actual" == "$expected_content" ]]; then
            printf "${GREEN}PASS${NC}\n"
            pass=$((pass + 1))
        else
            printf "${RED}FAIL${NC} (output differs)\n"
            diff <(echo "$actual") "$expected" | head -20
            fail=$((fail + 1))
        fi
    else
        # No expected file — just verify it produces valid-looking TOML
        if echo "$actual" | grep -q '^\[install\]'; then
            printf "${GREEN}PASS${NC} (produces [install] section)\n"
            pass=$((pass + 1))
        else
            printf "${RED}FAIL${NC} (no [install] section in output)\n"
            echo "$actual" | head -10
            fail=$((fail + 1))
        fi
    fi
}

smoke_test() {
    local name="$1"
    local input="$2"
    local check_pattern="$3"

    printf "  %-40s" "$name"

    local actual
    actual=$(DOCK2FLOX_SERVICES=container "$DOCK2FLOX" --dry-run "$input" 2>/dev/null) || {
        printf "${RED}FAIL${NC} (exit code $?)\n"
        fail=$((fail + 1))
        return 0
    }

    if echo "$actual" | grep -q "$check_pattern"; then
        printf "${GREEN}PASS${NC}\n"
        pass=$((pass + 1))
    else
        printf "${RED}FAIL${NC} (pattern not found: $check_pattern)\n"
        fail=$((fail + 1))
    fi
}

echo "dock2flox test suite"
echo "===================="
echo ""

# --- Dockerfile tests ---
echo "Dockerfile parsing:"

run_test "Python API (basic)" \
    "$FIXTURES/Dockerfile.python-api" \
    "$EXPECTED/python-api.toml"

run_test "Node.js (multi-stage)" \
    "$FIXTURES/Dockerfile.node" \
    "$EXPECTED/node.toml"

run_test "Go (multi-stage + ARG)" \
    "$FIXTURES/Dockerfile.multistage"

echo ""

# --- Smoke tests: verify specific mappings ---
echo "Package mapping smoke tests:"

smoke_test "apt curl -> curl" \
    "$FIXTURES/Dockerfile.python-api" \
    'curl.pkg-path = "curl"'

smoke_test "apt libpq-dev -> postgresql" \
    "$FIXTURES/Dockerfile.python-api" \
    'postgresql.pkg-path = "postgresql"'

smoke_test "apt build-essential -> gcc" \
    "$FIXTURES/Dockerfile.python-api" \
    'gcc.pkg-path = "gcc"'

smoke_test "FROM python:3.11 -> python311" \
    "$FIXTURES/Dockerfile.python-api" \
    'python311'

smoke_test "apk ca-certificates -> cacert" \
    "$FIXTURES/Dockerfile.multistage" \
    'cacert.pkg-path = "cacert"'

smoke_test "ENV APP_PORT -> [vars]" \
    "$FIXTURES/Dockerfile.multistage" \
    'APP_PORT = "8080"'

echo ""

# --- Compose tests ---
echo "Compose parsing:"

smoke_test "Compose: detects postgres vars" \
    "$FIXTURES/docker-compose.yml" \
    'PGHOST'

smoke_test "Compose: detects redis vars" \
    "$FIXTURES/docker-compose.yml" \
    'REDIS'

smoke_test "Compose: captures env vars" \
    "$FIXTURES/docker-compose.yml" \
    'APP_ENV'

echo ""

# --- Summary ---
echo "===================="
printf "Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, %d skipped\n" "$pass" "$fail" "$skip"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
