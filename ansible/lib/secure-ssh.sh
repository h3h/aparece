#!/usr/bin/env bash
#
# secure-ssh.sh — offer to close public SSH (UFW 22/tcp) once tailnet access
# is proven by the session that is running this script.
#
# Invoked as: bash "$(dirname "$0")/../lib/secure-ssh.sh" || true
#
# Every gate condition below must hold before the operator is prompted. The
# script never exits non-zero on an ordinary "gate did not pass" path, and it
# is safe to re-run: once the 22/tcp rule is gone it exits silently.
#
# Target: Ubuntu 24.04, bash 5.x, running as root.

set -euo pipefail

# One-line explanation for gate conditions 3-5, then a clean exit.
skip() {
    echo "  Public SSH lockdown not offered: $1"
    exit 0
}

# ---------------------------------------------------------------------------
# Gate 1: a TTY. Non-interactive runs stay completely silent.
# ---------------------------------------------------------------------------

[[ -t 0 ]] || exit 0

# ---------------------------------------------------------------------------
# Gate 2: a 22/tcp allow rule exists in UFW. If not, the host is already
# locked down (or UFW is inactive/unreadable) — a normal state, so exit
# silently with no message.
# ---------------------------------------------------------------------------

command -v ufw >/dev/null 2>&1 || exit 0

ufw_status_out="$(ufw status 2>&1)" || ufw_status_out=""

# Matches the "To" column of `ufw status` for a plain port rule, e.g.
#   22/tcp                     ALLOW       Anywhere
#   22/tcp (v6)                ALLOW       Anywhere (v6)
# Deliberately does not match LIMIT/DENY/REJECT rules, which
# `ufw delete allow 22/tcp` would not remove.
has_public_ssh_rule() {
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^22/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW([[:space:]]|$) ]]; then
            return 0
        fi
    done <<<"$1"
    return 1
}

has_public_ssh_rule "$ufw_status_out" || exit 0

# ---------------------------------------------------------------------------
# Gate 3: Tailscale SSH is enabled (RunSSH true in `tailscale debug prefs`).
#
# `tailscale debug prefs` is a debug-namespaced command with no output
# stability guarantee, and it prints a plain-text error when the daemon is
# unreachable. Anything that is not parseable JSON with RunSSH === true fails
# closed: no prompt.
# ---------------------------------------------------------------------------

if ! command -v tailscale >/dev/null 2>&1; then
    skip "the tailscale CLI is not installed."
fi

prefs_out="$(tailscale debug prefs 2>/dev/null)" || prefs_out=""

run_ssh="$(printf '%s' "$prefs_out" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
print("true" if data.get("RunSSH") is True else "false")
' 2>/dev/null)" || run_ssh=""

if [[ "$run_ssh" != "true" ]]; then
    skip "Tailscale SSH is not enabled (no RunSSH=true from 'tailscale debug prefs'); run 'sudo tailscale up --ssh' first."
fi

# ---------------------------------------------------------------------------
# Gate 4: BackendState is Running.
#
# With --json the CLI prints status and returns 0 even when logged out; it exits
# non-zero only when the daemon socket is unreachable. Output is captured
# regardless of exit code either way, and the content is what counts.
# ---------------------------------------------------------------------------

status_out="$(tailscale status --json 2>/dev/null)" || status_out=""

# Three lines: BackendState, first IPv4 tailnet address, MagicDNS name.
# Only the first is part of the gate; the other two are for the message text
# and may legitimately come back empty.
status_parsed="$(printf '%s' "$status_out" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)

state = data.get("BackendState")
if not isinstance(state, str):
    state = ""

self_node = data.get("Self")
if not isinstance(self_node, dict):
    self_node = {}

ips = self_node.get("TailscaleIPs")
if not isinstance(ips, list):
    ips = data.get("TailscaleIPs")
if not isinstance(ips, list):
    ips = []

v4 = ""
for ip in ips:
    if isinstance(ip, str) and "." in ip and ":" not in ip:
        v4 = ip
        break

dns = self_node.get("DNSName")
if not isinstance(dns, str):
    dns = ""
dns = dns.rstrip(".")

print(state)
print(v4)
print(dns)
' 2>/dev/null)" || status_parsed=""

backend_state="$(printf '%s\n' "$status_parsed" | sed -n '1p')"
tailnet_ip="$(printf '%s\n' "$status_parsed" | sed -n '2p')"
magic_dns="$(printf '%s\n' "$status_parsed" | sed -n '3p')"

if [[ "$backend_state" != "Running" ]]; then
    skip "this node is not connected to a tailnet (BackendState: ${backend_state:-unknown}); run 'sudo tailscale up --ssh' first."
fi

# Cosmetic only — the gate does not depend on knowing either of these.
ip_label="$tailnet_ip"
[[ -n "$ip_label" ]] || ip_label="its tailnet address"

# Name to use in the "reconnect from another device" hint. Prefer the MagicDNS
# name; fall back to the tailnet IPv4, then to this host's short hostname.
host_label="$magic_dns"
if [[ -z "$host_label" ]]; then
    host_label="$tailnet_ip"
fi
if [[ -z "$host_label" ]]; then
    host_label="$(hostname -s 2>/dev/null)" || host_label=""
fi
[[ -n "$host_label" ]] || host_label="<this-host>"

# ---------------------------------------------------------------------------
# Gate 5: this session arrived over the tailnet.
#
# Walk process ancestry from $$ to PID 1 via /proc/<pid>/stat and inspect each
# ancestor's comm. sudo appears as a descendant of the login shell and does not
# truncate the chain.
#
# /proc/<pid>/stat field 2 (comm) is wrapped in parentheses and may itself
# contain spaces and parentheses, so it is never safe to split the line on
# whitespace. comm is the text between the FIRST '(' and the LAST ')'; the
# numeric fields resume after that last ')', where field 1 is state and
# field 2 is ppid.
# ---------------------------------------------------------------------------

# Sets globals PROC_COMM and PROC_PPID. Returns 1 if the stat line is
# unreadable or malformed.
read_proc_stat() {
    local pid="$1"
    local line rest state ppid comm

    line="$(cat "/proc/${pid}/stat" 2>/dev/null)" || return 1
    [[ -n "$line" ]] || return 1
    [[ "$line" == *"("* && "$line" == *")"* ]] || return 1

    comm="${line#*(}"      # drop everything through the first '('
    comm="${comm%)*}"      # drop everything from the last ')'

    rest="${line##*)}"     # everything after the last ')'
    read -r state ppid _ <<<"$rest" || true

    [[ -n "$state" ]] || return 1
    [[ "$ppid" =~ ^[0-9]+$ ]] || return 1

    PROC_COMM="$comm"
    PROC_PPID="$ppid"
    return 0
}

# Reads SSH_CONNECTION out of another process's environment. /proc/<pid>/environ
# is NUL-separated and readable by root, which is what we run as.
#
# This exists because sudo's default env_reset drops SSH_* from our own
# environment, and the documented flow is `sudo aparece test tailscale` from a
# non-root user. Without this, the sshd-over-tailnet branch of gate 5 could
# never pass in normal use.
env_ssh_connection() {
    local pid="$1" kv
    [[ -r "/proc/${pid}/environ" ]] || return 1
    while IFS= read -r -d '' kv; do
        if [[ "$kv" == SSH_CONNECTION=* ]]; then
            printf '%s' "${kv#SSH_CONNECTION=}"
            return 0
        fi
    done < "/proc/${pid}/environ"
    return 1
}

PROC_COMM=""
PROC_PPID=""

saw_tailscaled=0
saw_sshd=0
ancestry=""
ancestor_pids=()

walk_pid="$$"
walk_iterations=0

while (( walk_pid > 1 && walk_iterations < 64 )); do
    walk_iterations=$(( walk_iterations + 1 ))

    read_proc_stat "$walk_pid" || break

    ancestor_pids+=("$walk_pid")

    # Recorded for the refusal message only. Capped so the message stays one
    # readable line on a deep process tree.
    if [[ -z "$ancestry" ]]; then
        ancestry="$PROC_COMM"
    elif (( walk_iterations <= 8 )); then
        ancestry="${ancestry} < ${PROC_COMM}"
    elif (( walk_iterations == 9 )); then
        ancestry="${ancestry} < ..."
    fi

    case "$PROC_COMM" in
        tailscaled)
            saw_tailscaled=1
            ;;
        # OpenSSH <9.8 names the per-connection process "sshd"; 9.8+ splits it
        # into "sshd-session". Ubuntu 24.04 ships 9.6, but both are accepted so
        # the check does not silently rot on a newer host.
        sshd | sshd-session)
            saw_sshd=1
            ;;
    esac

    # Guard against a stat line that reports itself as its own parent.
    (( PROC_PPID != walk_pid )) || break

    walk_pid="$PROC_PPID"
done

# An empty chain means even /proc/<self>/stat was unreadable, so nothing about
# this session can be verified. Fail closed.
if [[ -z "$ancestry" ]]; then
    skip "could not read /proc/$$/stat, so there is no way to verify how this session connected."
fi

# SSH_CONNECTION is "<client-ip> <client-port> <server-ip> <server-port>".
# Field 1 is where the client came from; field 3 is the local address it
# reached. Both matter — see below.
#
# Our own copy is usually missing: the documented invocation is
# `sudo aparece test tailscale`, and sudo's default env_reset strips SSH_*.
# Fall back to the environment of the nearest ancestor that still has it —
# the pre-sudo login shell.
ssh_conn_raw="${SSH_CONNECTION:-}"

if [[ -z "$ssh_conn_raw" ]]; then
    for ancestor_pid in "${ancestor_pids[@]}"; do
        if ssh_conn_raw="$(env_ssh_connection "$ancestor_pid")" && [[ -n "$ssh_conn_raw" ]]; then
            break
        fi
        ssh_conn_raw=""
    done
fi

ssh_conn_fields=()
read -r -a ssh_conn_fields <<<"$ssh_conn_raw" || true
ssh_source="${ssh_conn_fields[0]:-}"
ssh_local="${ssh_conn_fields[2]:-}"

# A Tailscale address is either 100.64.0.0/10 (CGNAT space, IPv4) or
# fd7a:115c:a1e0::/48 (Tailscale's ULA range, IPv6).
is_tailnet_addr() {
    local addr="${1,,}"

    # IPv6: Tailscale's /48 is a fixed three-group prefix.
    [[ "$addr" == fd7a:115c:a1e0:* ]] && return 0

    # IPv4: first octet exactly 100, second octet 64-127 inclusive.
    # 10# forces base 10 so a zero-padded octet is not read as octal.
    [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    (( 10#${BASH_REMATCH[1]} == 100 )) || return 1
    (( 10#${BASH_REMATCH[2]} >= 64 )) || return 1
    (( 10#${BASH_REMATCH[2]} <= 127 )) || return 1
    return 0
}

session_kind=""

if (( saw_tailscaled == 1 )); then
    session_kind="tailscale-ssh"
elif (( saw_sshd == 1 )); then
    # Both ends of the connection must be tailnet addresses.
    #
    # The client source alone is only a proxy: 100.64.0.0/10 is shared CGNAT
    # space, so a client behind carrier-grade NAT could present a source in
    # that range while connecting to the PUBLIC address — and closing 22/tcp
    # would then cut exactly the session that authorised it. Requiring the
    # local address (field 3) to be a tailnet address as well proves the
    # connection actually terminated on the tailscale0 interface, which is the
    # property that makes closing the public port safe.
    if [[ -z "$ssh_source" || -z "$ssh_local" ]]; then
        skip "this sshd session reports no usable SSH_CONNECTION, so it cannot be shown to be on the tailnet; closing 22/tcp could cut it."
    elif ! is_tailnet_addr "$ssh_local"; then
        skip "this SSH session reached this host at ${ssh_local}, not a tailnet address; closing 22/tcp would cut it."
    elif ! is_tailnet_addr "$ssh_source"; then
        skip "this SSH session comes from ${ssh_source}, which is not a tailnet address; closing 22/tcp would cut it."
    else
        session_kind="sshd-over-tailnet"
    fi
else
    skip "this session did not arrive over the tailnet (ancestry: ${ancestry}); reconnect with 'tailscale ssh' or 'ssh ${ip_label}' and try again."
fi

# ---------------------------------------------------------------------------
# The prompt. Default is N — a bare Enter must not lock anything down.
# ---------------------------------------------------------------------------

echo ""
echo "Tailscale SSH is working and this session is on the tailnet (${ip_label})."

if [[ "$session_kind" == "sshd-over-tailnet" ]]; then
    echo ""
    echo "  WARNING: this is an ordinary sshd session reaching the node over the"
    echo "           tailnet (from ${ssh_source}), not a Tailscale SSH session."
    echo "           Tailscale SSH is enabled but has not been proven by this"
    echo "           session. The sshd path below is the one that is proven."
fi

echo ""
echo "  Public SSH can now be closed:"
echo "    - DELETE ufw rule: 22/tcp ALLOW Anywhere (v4 and v6)"
echo "    - Tailscale SSH is unaffected"
echo "    - sshd keeps running as a fallback: while Tailscale SSH is on it"
echo "      serves ${ip_label}:22, so sshd takes over there only if you later"
echo "      turn Tailscale SSH off ('tailscale set --ssh=false')"
echo ""

reply=""
read -r -p "Close public SSH now? [y/N] " reply || reply=""

if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo ""
    echo "Leaving public SSH open. Nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply.
# ---------------------------------------------------------------------------

echo ""
if ! ufw delete allow 22/tcp; then
    echo ""
    echo "'ufw delete allow 22/tcp' failed. Public SSH is unchanged and still open."
    exit 0
fi

echo ""
ufw status || true

echo ""
echo "Public SSH is closed. Before you end this session:"
echo ""
echo "  1. From ANOTHER device on the tailnet, confirm you can still get in:"
echo "       tailscale ssh ${host_label}"
echo "       ssh ${ip_label}"
echo ""
echo "  2. Undo, if anything is wrong:"
echo "       sudo ufw allow 22/tcp"
echo ""
echo "  3. If both tailnet paths are gone (for example an expired node key),"
echo "     your cloud provider's serial or web console is the remaining"
echo "     out-of-band way in. Run the undo command from there."
echo ""
echo "Keep this session open until step 1 succeeds."

exit 0
