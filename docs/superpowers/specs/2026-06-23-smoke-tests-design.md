# Smoke Tests for Network Services

**Date:** 2026-06-23
**Scope:** Post-activation smoke tests for PostgreSQL and Redis

## Summary

After `aparece activate <app>` completes for a network-accessible service, run a suite of three security-focused smoke tests. If any test fails, stop the service and exit non-zero so the server is never left in a potentially insecure state.

Tests are also available on demand via `aparece test <app>`.

## File Structure

New files:

```
ansible/
  tests/
    postgresql.sh
    redis.sh
```

Synced to `/opt/aparece/ansible/tests/` by the existing rsync in `aparece bootstrap`. No changes to the bootstrap flow.

No changes to app metadata YAML files. The `cmd_test` function uses the existing `service_name` field to determine which service to stop on failure.

Credential files at `/opt/aparece/credentials/` are not used — the auth check intentionally uses a wrong password to verify rejection, and the banner check inspects unauthenticated error responses.

## Remote CLI Changes (`templates/aparece-remote.sh`)

### New `cmd_test` function

```bash
cmd_test() {
    local app="$1"
    validate_app "$app"

    local test_script="${ANSIBLE_DIR}/tests/${app}.sh"

    if [[ ! -f "$test_script" ]]; then
        log "No smoke tests defined for ${app} — skipping"
        return 0
    fi

    log "Running smoke tests for ${app}..."
    echo ""

    if bash "$test_script"; then
        echo ""
        log "All smoke tests passed for ${app}."
        return 0
    else
        local service
        service="$(parse_meta "${METADATA_DIR}/${app}.yml" service_name)"
        if [[ -n "$service" ]]; then
            log "Stopping ${service} due to failed smoke tests..."
            systemctl stop "$service"
        fi
        error "Smoke tests failed for ${app}. Service has been stopped."
    fi
}
```

### `cmd_activate` — add at end

Call `cmd_test "$app"` after the summary block. Failure propagates via exit 1.

### Main dispatch — add case

```bash
test)
    [[ $# -lt 2 ]] && error "Usage: aparece test <app>"
    cmd_test "$2"
    ;;
```

Apps without a test script (e.g. `python`, `ruby`, `bun`) skip silently — no noise for non-network services.

## Test Scripts

### Shared helper pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "  [FAIL] $1"
    [[ -n "${2:-}" ]] && echo "         $2"
    exit 1
}
pass() { echo "  [PASS] $1"; }
```

### PostgreSQL (`ansible/tests/postgresql.sh`)

**Check 1 — TCP connection on port 5432:**
```bash
nc -z -w5 127.0.0.1 5432
```
Failure: connection refused or timeout. Verifies the process is listening on the network, not just that systemd reports it active.

**Check 2 — Authentication required:**
```bash
PGPASSWORD="__wrong__" psql -h 127.0.0.1 -U postgres -d postgres \
    --connect-timeout=5 -c "SELECT 1" 2>&1
```
Three distinct outcomes, each handled explicitly:
- Exit 0 → connection accepted without valid credentials → `[FAIL] Accepted unauthenticated connection`
- Exit non-zero + output contains `password authentication failed` → auth is enforced → `[PASS]`
- Exit non-zero + output does not contain `password authentication failed` → unexpected error (misconfiguration, wrong port, etc.) → `[FAIL] Unexpected error: <output>`

The third case surfaces configuration problems (e.g. `FATAL: role "postgres" does not exist`) that would otherwise look like a passing test.

**Check 3 — No version in error response:**
Grep the auth-failure output from Check 2 for a version string:
```bash
grep -qiE 'PostgreSQL\s+[0-9]|server version\s+[0-9]'
```
Context-anchored pattern avoids false positives from IP addresses or port numbers in psql error output. Failure if the pattern matches.

### Redis (`ansible/tests/redis.sh`)

**Check 1 — TCP connection on port 6379:**
```bash
nc -z -w5 127.0.0.1 6379
```

**Check 2 — Authentication required:**
```bash
redis-cli -h 127.0.0.1 PING 2>&1
```
Three distinct outcomes:
- Response is `PONG` → auth not enforced → `[FAIL] Accepted unauthenticated connection`
- Response contains `NOAUTH` → auth is enforced → `[PASS]`
- Any other response → unexpected → `[FAIL] Unexpected response: <output>`

Mirrors the PostgreSQL Check 2 logic: an unexpected non-rejection is as much a failure as silent acceptance.

**Check 3 — No version in error response:**
Grep the `NOAUTH` response for a semver pattern:
```bash
grep -qE '[0-9]+\.[0-9]+\.[0-9]+'
```
Redis error responses are terse and contain no version, but this makes the absence explicit. Safe to use bare semver pattern here given the short, structured response format.

## Failure Behavior

Test scripts print `[FAIL]` with detail and exit 1. `cmd_test` in the remote CLI then stops the service and exits 1.

Sample failure (Redis check 2):

```
[aparece] Running smoke tests for redis...

  [PASS] TCP connection accepted on 127.0.0.1:6379
  [FAIL] Unauthenticated access not rejected
         Response was: +PONG

[aparece] Stopping redis-server due to failed smoke tests...
[aparece] ERROR: Smoke tests failed for redis. Service has been stopped.
```

Sample success:

```
[aparece] Running smoke tests for redis...

  [PASS] TCP connection accepted on 127.0.0.1:6379
  [PASS] Unauthenticated access rejected (NOAUTH)
  [PASS] No version string in error response

[aparece] All smoke tests passed for redis.
```

## Scope Boundaries

- Version check covers connection banner and unauthenticated error responses only — not post-auth queries (`SELECT version()`, `INFO server`).
- `nc` (netcat-openbsd) is used for TCP checks; available by default on Ubuntu 24.04.
- Tests are not defined for non-network services (`python`, `ruby`, `bun`, `duckdb`, `awscli`, `direnv`, etc.). `cmd_test` skips them silently.
- No changes to Ansible roles, playbooks, or app metadata.
