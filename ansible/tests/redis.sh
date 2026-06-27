#!/usr/bin/env bash
set -euo pipefail

pass() { echo "  [PASS] $1"; }
fail() {
    echo "  [FAIL] $1"
    [[ -n "${2:-}" ]] && echo "         $2"
    exit 1
}

# Check 1: TCP connection on port 6379
if nc -z -w5 127.0.0.1 6379 2>/dev/null; then
    pass "TCP connection accepted on 127.0.0.1:6379"
else
    fail "Cannot connect to 127.0.0.1:6379" "Is Redis running and listening?"
fi

# Check 2: Authentication required
noauth_output=$(redis-cli -h 127.0.0.1 PING 2>&1)

if [[ "$noauth_output" == "PONG" ]]; then
    fail "Accepted unauthenticated connection" "Redis responded to PING without AUTH"
elif echo "$noauth_output" | grep -q "NOAUTH"; then
    pass "Unauthenticated access rejected (NOAUTH)"
else
    fail "Unexpected response during auth check" "$noauth_output"
fi

# Check 3: No version in error response
if echo "$noauth_output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    fail "Version string visible in error response" "$noauth_output"
else
    pass "No version string in error response"
fi
