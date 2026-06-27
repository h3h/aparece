#!/usr/bin/env bash
set -euo pipefail

pass() { echo "  [PASS] $1"; }
fail() {
    echo "  [FAIL] $1"
    [[ -n "${2:-}" ]] && echo "         $2"
    exit 1
}

# Check 1: TCP connection on port 5432
if nc -z -w5 127.0.0.1 5432 2>/dev/null; then
    pass "TCP connection accepted on 127.0.0.1:5432"
else
    fail "Cannot connect to 127.0.0.1:5432" "Is PostgreSQL running and listening?"
fi

# Check 2 & 3 share the same auth-attempt output
auth_output=$(PGPASSWORD="__wrong__" psql -h 127.0.0.1 -U postgres -d postgres \
    --connect-timeout=5 -c "SELECT 1" 2>&1) && auth_exit=0 || auth_exit=$?

# Check 2: Authentication required
if [[ $auth_exit -eq 0 ]]; then
    fail "Accepted unauthenticated connection" "PostgreSQL connected successfully with wrong password"
elif echo "$auth_output" | grep -q "password authentication failed"; then
    pass "Unauthenticated access rejected (password authentication failed)"
else
    fail "Unexpected error during auth check" "$auth_output"
fi

# Check 3: No version in error response
if echo "$auth_output" | grep -qiE 'PostgreSQL\s+[0-9]|server version\s+[0-9]'; then
    fail "Version info visible in authentication error" "$auth_output"
else
    pass "No version string in error response"
fi
