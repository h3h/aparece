#!/usr/bin/env bash
set -euo pipefail

pass() { echo "  [PASS] $1"; }
info() { echo "         $1"; }
fail() {
    echo "  [FAIL] $1"
    [[ -n "${2:-}" ]] && echo "         $2"
    exit 1
}

# Check 1: Binary responds
if version_output=$(tailscale version 2>&1); then
    pass "tailscale binary responds (${version_output%%$'\n'*})"
else
    fail "tailscale binary did not respond" "$version_output"
fi

# Check 2: Daemon running
if systemctl is-active --quiet tailscaled; then
    pass "tailscaled is active"
else
    fail "tailscaled is not active" "Try: sudo systemctl start tailscaled"
fi

# Check 3: Daemon socket responsive
# With --json, 'tailscale status' prints the status and returns 0 even when the
# node is logged out, so NeedsLogin arrives here as ordinary JSON. It does exit
# non-zero when the daemon socket is unreachable, which is the case this check
# exists to catch — so capture output regardless of exit code and judge content.
status_output=$(tailscale status --json 2>&1) || true

# Emits the backend state on line 1 and the tailnet IPv4 (if any) on line 2.
parsed=$(printf '%s' "$status_output" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)

state = data.get("BackendState")
if not isinstance(state, str) or not state.strip():
    sys.exit(1)

self_status = data.get("Self") or {}
ips = data.get("TailscaleIPs") or self_status.get("TailscaleIPs") or []
ip = ""
for candidate in ips:
    if isinstance(candidate, str) and candidate and ":" not in candidate:
        ip = candidate
        break

print(state.strip())
print(ip)
') || parsed=""

if [[ -z "$parsed" ]]; then
    fail "Cannot read daemon state" "tailscale status --json did not report BackendState"
fi

mapfile -t parsed_lines <<<"$parsed"
backend_state="${parsed_lines[0]}"
tailnet_ip="${parsed_lines[1]:-}"

pass "Daemon socket responsive (state: ${backend_state})"

# Connection state is reported, never graded: a freshly activated node reports
# NeedsLogin, and failing on that would stop tailscaled after every activation.
if [[ "$backend_state" == "Running" ]]; then
    if [[ -n "$tailnet_ip" ]]; then
        info "Connected — tailnet IPv4: ${tailnet_ip}"
    else
        info "Connected — tailnet IPv4 not reported by the daemon"
    fi
else
    info "Not connected — run 'sudo tailscale up --ssh' to join a tailnet"
fi

# Lockdown offer. The '|| true' is load-bearing: a non-zero exit here would make
# cmd_test treat the smoke tests as failed and stop tailscaled, tearing down the
# network the operator may be connected through. The helper reports its own errors.
bash "$(dirname "$0")/../lib/secure-ssh.sh" || true
