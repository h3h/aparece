# Tailscale App and SSH Lockdown

**Date:** 2026-08-05
**Scope:** Tailscale as an activatable app, an optional `notes` field in app metadata, and a gated lockdown that closes public SSH once tailnet access is proven

## Summary

Add `tailscale` to the app catalog so a bootstrapped server can join a tailnet and be reached by MagicDNS name instead of a public IP. Activation installs the package, enables `tailscaled`, and opens UDP 41641 — but deliberately stops short of authenticating. The operator finishes setup by running `sudo tailscale up --ssh` themselves.

Once the node is on the tailnet with Tailscale SSH enabled, `aparece test tailscale` offers to close public SSH. The offer is gated on proof that the current session is already reaching the box over the tailnet, so accepting it cannot sever the connection running it.

### Why install-only

`tailscale up` blocks waiting for the operator to visit a login URL, and Ansible buffers command output until a task completes — so running it inside the role would hang with no URL on screen. Working around that means launching it async, polling `tailscale status --json` for the `AuthURL`, printing it, then waiting for `BackendState=Running` with a timeout. Install-only trades one manual command for none of that machinery.

Authentication is interactive by design. No auth keys are passed through the CLI, stored on disk, or read from the environment, so activation handles no secrets.

## Security Model Consequence

Installing Tailscale changes the exposure of *every* service on the host, whether or not this spec touches them.

tailscaled inserts a `ts-input` chain at the top of iptables' `INPUT` chain containing a blanket ACCEPT for the `tailscale0` interface. That rule is evaluated ahead of UFW's. Two consequences follow, and both matter:

1. **UFW does not gate tailnet traffic.** Any service listening on `0.0.0.0` becomes reachable from the tailnet at `100.x.y.z:<port>` regardless of UFW rules. PostgreSQL and Redis both enforce authentication (see the smoke tests spec), so this is authenticated, tailnet-only reachability rather than public exposure — but it is a real widening of the reachable surface and should not be discovered by accident.
2. **Closing port 22 does not break SSH over the tailnet.** This is what makes the lockdown safe, and it is the mechanism Tailscale's own Ubuntu guide relies on.

Anything that must stay off the tailnet has to bind to `127.0.0.1` rather than rely on the firewall.

## File Structure

New files:

```
ansible/
  roles/tailscale/tasks/main.yml
  app_metadata/tailscale.yml
  tests/tailscale.sh
  lib/secure-ssh.sh
```

Modified:

```
templates/aparece-remote.sh    # print the notes field
README.md                      # app table + project structure
```

All new files sync to `/opt/aparece/ansible/` via the existing rsync in `aparece bootstrap`. No changes to the bootstrap flow, `activate.yml`, or the security role.

## Role (`ansible/roles/tailscale/tasks/main.yml`)

Installs from Tailscale's official APT repository, mirroring upstream's documented procedure:

```yaml
- name: Add Tailscale APT signing key
  get_url:
    url: https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg
    dest: /usr/share/keyrings/tailscale-archive-keyring.gpg
    owner: root
    group: root
    mode: "0644"

- name: Add Tailscale APT repository
  get_url:
    url: https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-list
    dest: /etc/apt/sources.list.d/tailscale.list
    owner: root
    group: root
    mode: "0644"
  register: tailscale_repo

- name: Install Tailscale
  apt:
    name: tailscale
    state: present
    update_cache: yes

- name: Enable and start tailscaled
  systemd:
    name: tailscaled
    enabled: yes
    state: started

- name: Verify Tailscale installation
  command: tailscale version
  register: tailscale_installed_version
  changed_when: false

- name: Display Tailscale version
  debug:
    msg: "Tailscale installed: {{ tailscale_installed_version.stdout_lines[0] }}"
```

Notes on the choices:

- The repo list file is fetched rather than declared via `apt_repository` so the `signed-by` pointer and suite name come from upstream. `get_url` is idempotent on content.
- No architecture assert. Unlike the chromium role, Tailscale publishes both amd64 and arm64, so there is no host to exclude.
- The `.deb` postinst already enables `tailscaled`; the explicit `systemd` task asserts that state rather than inheriting it, and covers a host where it was previously disabled.
- Hardcodes the `noble` suite, consistent with the project's Ubuntu 24.04-only target (asserted in `bootstrap.yml`).

## Metadata (`ansible/app_metadata/tailscale.yml`)

```yaml
description: "Tailscale mesh VPN (WireGuard)"
ufw_ports:
  - { port: "41641", proto: "udp" }
binary_path: "/usr/bin/tailscale"
service_name: "tailscaled"
log_paths: []
notes: |
  Not connected to a tailnet yet. Finish setup with:

    sudo tailscale up --ssh

  The --ssh flag enables Tailscale SSH, which is required before aparece will
  offer to close public SSH.

  Then reach this host by its MagicDNS name from any tailnet device.
  Connection persists across reboots — no need to run 'up' again.

  Once connected over the tailnet, run:

    sudo aparece test tailscale

  to verify the connection and be offered the public-SSH lockdown.

  Recommended for servers: disable key expiry for this machine in the
  Tailscale admin console, otherwise it drops off the tailnet in 180 days
  and needs an interactive re-auth.

  Logs: journalctl -u tailscaled
```

UDP 41641 is opened by the existing `post_tasks` loop in `activate.yml`; the role contains no firewall code. Without it Tailscale still works, falling back to NAT traversal and DERP relays, but direct peer connections are preferred. The port speaks only WireGuard, which silently drops unauthenticated packets.

`log_paths` is empty because tailscaled logs to journald. Putting a `journalctl` invocation in a list of file paths would misrepresent the field, so the journal hint lives in `notes`.

### Reboot persistence

`tailscale up` writes the node key and preferences to `/var/lib/tailscale/tailscaled.state`. On boot, tailscaled reads that state and reconnects without intervention — hence the reassurance in `notes`. Two consequences worth recording:

- `tailscale down` persists the same way. A downed node stays down across reboots until `up` is run again.
- Node keys expire after 180 days by default, dropping the node off the tailnet and requiring interactive re-auth. For an unattended server that is precisely the wrong failure mode, so `notes` points at the admin console toggle while the operator is already there finishing the login. **This matters more once public SSH is closed:** an expired node key removes the only remaining path in.

## Remote CLI Changes (`templates/aparece-remote.sh`)

Add an optional `notes` field to the metadata contract, printed at the end of `cmd_activate`:

```bash
notes="$(parse_meta "$meta" notes)"
...
if [[ -n "$notes" ]]; then
    echo ""
    echo "$notes"
fi
```

**An `if` block is required here — the obvious `[[ -n "$notes" ]] && { ...; }` one-liner is a bug.** Under `set -euo pipefail`, when `notes` is empty the failing `[[ ]]` is the left operand of `&&`, so `set -e` does not fire, but the compound list's exit status is 1 and becomes the function's return value. The call site `cmd_activate "$2"` inside the `case` is an unprotected simple command, so `set -e` then fires and the script exits 1 — for every app without a `notes` field, which is all ten existing ones. An `if` with a false condition and no `else` exits 0, so no trailing `true` guard is needed.

Placed **after** the `cmd_test "$app"` call so the instruction is the last thing on screen rather than being scrolled away by test output. On smoke-test failure `cmd_test` exits non-zero and the notes never print, which is correct — a broken install has no next step to offer.

No change to `parse_meta`. Its scalar branch (`print(val)`) passes a multi-line block scalar through unchanged.

The field is generic and optional. Apps without it are unaffected, and others may adopt it later.

**No other CLI changes.** The lockdown prompt deliberately does not live in `cmd_test`, which is app-agnostic. It lives in the tailscale test script, which is already app-specific.

## Smoke Test (`ansible/tests/tailscale.sh`)

The test must pass on a freshly installed, not-yet-connected node. `cmd_test` stops the service on failure, so asserting "connected" would stop tailscaled after every activation — the opposite of useful.

Uses the shared `pass`/`fail` helper pattern from the existing test scripts.

**Check 1 — Binary responds:**
```bash
tailscale version
```
Failure: missing or non-functional binary.

**Check 2 — Daemon running:**
```bash
systemctl is-active --quiet tailscaled
```

**Check 3 — Daemon socket responsive:**
```bash
tailscale status --json 2>&1
```
Output is captured regardless of exit code. Note that with `--json` the CLI prints status and returns **0** even when logged out — the `--json` branch of `runStatus` returns before the check that would exit non-zero — so `NeedsLogin` arrives here as ordinary JSON. It exits non-zero only when the daemon socket is unreachable, which is precisely the failure this check exists to catch. The output is parsed with `python3 -c` (already a dependency of `parse_meta`) and the test passes if `BackendState` is present and non-empty — proving the CLI reached the daemon over its socket. A parse failure or missing field is `[FAIL] Cannot read daemon state`.

**Connection state — reported, not graded:**

The value of `BackendState` is printed for information:
- `Running` → print the tailnet IPv4 from `TailscaleIPs[0]`
- anything else (`NeedsLogin`, `Stopped`, `Starting`, `NoState`) → print a reminder to run `sudo tailscale up --ssh`

Neither outcome fails the test. A freshly activated node reports `NeedsLogin`, which is the expected end state of activation.

**Lockdown offer — after all checks:**
```bash
bash "$(dirname "$0")/../lib/secure-ssh.sh" || true
```

The `|| true` is load-bearing. A non-zero exit from this script makes `cmd_test` stop `tailscaled` — a hiccup in the lockdown must never tear down the network the operator is connected through. The helper reports its own errors.

Sample output immediately after activation:

```
[aparece] Running smoke tests for tailscale...

  [PASS] tailscale binary responds (1.90.2)
  [PASS] tailscaled is active
  [PASS] Daemon socket responsive (state: NeedsLogin)
         Not connected — run 'sudo tailscale up --ssh' to join a tailnet

[aparece] All smoke tests passed for tailscale.
```

## SSH Lockdown (`ansible/lib/secure-ssh.sh`)

### End state

Public SSH is closed by deleting the UFW `22/tcp` rule. **sshd keeps running and stays enabled.** This leaves two independent ways in over the tailnet:

1. Tailscale SSH, served by tailscaled
2. Ordinary sshd, reached at the node's `100.x.y.z` address

Both survive because `ts-input` accepts `tailscale0` traffic ahead of UFW. Keeping sshd means a tailnet ACL change that breaks Tailscale SSH does not lock the operator out — their existing keys still work. Both paths do depend on the tailnet itself, so an expired node key still ends in the cloud console.

`ufw allow in on tailscale0` is deliberately **not** added. Tailscale's own `ts-input` rule already accepts everything on that interface ahead of UFW, so the rule would be decorative.

### The gate

Every condition must hold. On failure the helper prints one line explaining why and exits 0 without prompting — except for conditions 1 and 2, which exit silently, since a non-interactive run and an already-locked-down host are both normal states rather than something to report.

1. **A TTY** — `[[ -t 0 ]]`, so non-interactive runs stay silent
2. **A `22/tcp` allow rule exists in UFW** — otherwise already locked down; exit silently, no message
3. **`RunSSH: true`** — parsed from `tailscale debug prefs`
4. **`BackendState` is `Running`** — from `tailscale status --json`
5. **The current session arrived over the tailnet**, determined by walking process ancestry from `$$` to PID 1 via `/proc/<pid>/stat` and comparing each ancestor's `comm`:
   - ancestry contains `tailscaled` → Tailscale SSH session → pass
   - ancestry contains `sshd` (or `sshd-session`, the OpenSSH ≥ 9.8 name) **and both ends of `SSH_CONNECTION` are tailnet addresses** → sshd-over-tailnet → pass, with a printed warning that Tailscale SSH itself remains unproven
   - otherwise → refuse, explaining that closing port 22 would cut the current connection

   A tailnet address is `100.64.0.0/10` (IPv4 CGNAT space) or `fd7a:115c:a1e0::/48` (Tailscale's IPv6 ULA range).

   **Both ends must match, not just the client source.** `100.64.0.0/10` is shared CGNAT space, so a client behind carrier-grade NAT can present a source address in that range while connecting to the host's *public* address. Checking the source alone would pass that session and then cut it. Requiring `SSH_CONNECTION` field 3 — the local address the client reached — to also be a tailnet address proves the connection terminated on the `tailscale0` interface, which is the property that actually makes closing the public port safe.

Condition 5 is the substance of the verification. A status check can only report what the daemon believes; the session's own provenance is proof that the path being preserved actually carries traffic. Because the operator is connected through a path that survives the change, accepting the prompt cannot disconnect them.

Ancestry walking is unaffected by `sudo`, which appears as a descendant of the login shell and does not truncate the chain.

### The prompt

On a passing gate, print the exact change and prompt with **N as the default**:

```
Tailscale SSH is working and this session is on the tailnet (100.x.y.z).

  Public SSH can now be closed:
    - DELETE ufw rule: 22/tcp ALLOW Anywhere (v4 and v6)
    - sshd keeps running, reachable at 100.x.y.z
    - Tailscale SSH is unaffected

Close public SSH now? [y/N]
```

On `y`: run `ufw delete allow 22/tcp`, which removes both the v4 and v6 rules created by the security role. Then print `ufw status`, followed by:

- the undo: `sudo ufw allow 22/tcp`
- a note that the cloud provider's serial or web console is the out-of-band recovery path
- **a reminder to confirm access from another device before ending this session**

### Interaction with `activate`

`cmd_activate` calls `cmd_test` at the end, so the helper runs during activation too. It cannot prompt there: a freshly activated node has not been through `tailscale up`, so `BackendState` is `NeedsLogin` and conditions 3–5 all fail. The prompt appears only on a deliberate `aparece test tailscale` from a tailnet session.

The narrow exception is re-running `aparece activate tailscale` later, from a tailnet session, on a host that still has the port 22 rule. The prompt fires mid-activation. This is acceptable: it is interactive, defaults to N, and the gate conditions that make it safe are identical.

### fail2ban

Once public SSH is closed, fail2ban's sshd jail protects a port nothing can reach. It is already `state: stopped` in the security role (marked TODO), so no change is needed. Worth revisiting if that TODO is ever resolved.

## Documentation

`README.md` gains a row in the app table:

| App | Description | Port(s) | Service |
|-----|-------------|---------|---------|
| tailscale | Tailscale mesh VPN | 41641/udp | tailscaled |

entries for `tailscale.yml`, `roles/tailscale/`, and `lib/secure-ssh.sh` in the project structure block, and a short subsection covering the lockdown flow and the fact that Tailscale bypasses UFW on `tailscale0`.

## Testing

Per `AGENTS.md`, Ansible roles cannot be run or tested on macOS. Verification happens on an Ubuntu 24.04 target.

Installation:

1. `sudo aparece activate tailscale` — installs cleanly, smoke tests pass, notes print last, **no lockdown prompt appears**
2. `sudo aparece activate tailscale` again — idempotent, no changed tasks beyond apt cache
3. `sudo tailscale up --ssh` — completes login, node appears in the admin console
4. `sudo ufw status` — shows `41641/udp ALLOW`
5. Reboot — node rejoins the tailnet with no intervention

Gate behavior:

6. From a **public-IP** SSH session: `sudo aparece test tailscale` reports `Running` with the tailnet IP and **refuses to prompt**, explaining the session is not on the tailnet
7. From a **Tailscale SSH** session (`tailscale ssh <host>`): the prompt appears; answering `N` changes nothing
8. From an **sshd-over-tailnet** session (`ssh 100.x.y.z`): the prompt appears with the Tailscale-SSH-unproven warning
9. Piped input (`echo | sudo aparece test tailscale`): no prompt, no hang

After lockdown:

10. Answer `y` from a Tailscale SSH session — `ufw status` no longer lists `22/tcp`
11. `ssh <public-ip>` from off-tailnet — times out
12. `tailscale ssh <host>` — still works
13. `ssh 100.x.y.z` — still works, confirming the sshd fallback
14. Reboot — both tailnet paths return; public SSH stays closed
15. `sudo aparece test tailscale` again — no prompt (no `22/tcp` rule to delete), tests still pass
16. `sudo ufw allow 22/tcp` — the documented undo restores public SSH

## Scope Boundaries

- No auth keys, OAuth clients, or unattended enrollment. Login is interactive.
- No `tailscale serve` / `funnel`, exit-node configuration, subnet routing, or the IP forwarding sysctls those require.
- The lockdown closes public SSH only. It does not touch the UFW rules for PostgreSQL, Redis, or nginx — though per the Security Model Consequence section, those services are tailnet-reachable regardless of UFW once Tailscale is installed.
- sshd is never disabled, and its config is never modified. No `ListenAddress` binding to the tailnet IP: that address is assigned by Tailscale, and pinning it in `sshd_config` breaks sshd on any boot where it starts before `tailscale0` has an address.
- No auto-revert timer. The session gate makes lockout unlikely enough that a background job silently reopening port 22 is the larger risk.
- No changes to `bootstrap.yml`, the security role, or any other app's metadata.
- `aparece status tailscale` reports `ACTIVE` whenever tailscaled is running, including when the node is logged out and connected to nothing. Accurate reporting needs per-app status hooks — a change to the shared metadata contract beyond this feature's scope. The smoke test is the place that reports real connection state.
- `tailscale debug prefs` is a debug-namespaced command and its output is not a stability guarantee. If the `RunSSH` field moves, gate condition 3 fails closed — the prompt stops appearing, which is the safe direction.
