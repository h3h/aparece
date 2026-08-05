# Tailscale App

**Date:** 2026-08-05
**Scope:** Tailscale as an activatable app, plus an optional `notes` field in app metadata

## Summary

Add `tailscale` to the app catalog so a bootstrapped server can join a tailnet and be reached by MagicDNS name instead of a public IP. Activation installs the package, enables `tailscaled`, and opens UDP 41641 — but deliberately stops short of authenticating. The operator finishes setup by running `sudo tailscale up` themselves.

Other apps keep their current exposure. This does not change how PostgreSQL, Redis, or nginx are reached, and does not use `tailscale serve`, exit nodes, or subnet routing.

### Why install-only

`tailscale up` blocks waiting for the operator to visit a login URL, and Ansible buffers command output until a task completes — so running it inside the role would hang with no URL on screen. Working around that means launching it async, polling `tailscale status --json` for the `AuthURL`, printing it, then waiting for `BackendState=Running` with a timeout. Install-only trades one manual command for none of that machinery.

Authentication is interactive by design. No auth keys are passed through the CLI, stored on disk, or read from the environment, so activation handles no secrets.

## File Structure

New files:

```
ansible/
  roles/tailscale/tasks/main.yml
  app_metadata/tailscale.yml
  tests/tailscale.sh
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

    sudo tailscale up

  Then reach this host by its MagicDNS name from any tailnet device.
  Connection persists across reboots — no need to run 'up' again.

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
- Node keys expire after 180 days by default, dropping the node off the tailnet and requiring interactive re-auth. For an unattended server that is precisely the wrong failure mode, so `notes` points at the admin console toggle while the operator is already there finishing the login.

## Remote CLI Changes (`templates/aparece-remote.sh`)

Add an optional `notes` field to the metadata contract, printed at the end of `cmd_activate`:

```bash
notes="$(parse_meta "$meta" notes)"
[[ -n "$notes" ]] && { echo ""; echo "$notes"; }
```

Placed **after** the `cmd_test "$app"` call so the instruction is the last thing on screen rather than being scrolled away by test output. On smoke-test failure `cmd_test` exits non-zero and the notes never print, which is correct — a broken install has no next step to offer.

No change to `parse_meta`. Its scalar branch (`print(val)`) passes a multi-line block scalar through unchanged.

The field is generic and optional. Apps without it are unaffected, and others may adopt it later.

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
Output is captured regardless of exit code, because `tailscale status` exits non-zero when the node is logged out. The output is parsed with `python3 -c` (already a dependency of `parse_meta`) and the test passes if `BackendState` is present and non-empty — proving the CLI reached the daemon over its socket. A parse failure or missing field is `[FAIL] Cannot read daemon state`.

**Connection state — reported, not graded:**

The value of `BackendState` is printed for information:
- `Running` → print the tailnet IPv4 from `TailscaleIPs[0]`
- anything else (`NeedsLogin`, `Stopped`, `Starting`, `NoState`) → print a reminder to run `sudo tailscale up`

Neither outcome fails the test. A freshly activated node reports `NeedsLogin`, which is the expected end state of activation.

Sample output immediately after activation:

```
[aparece] Running smoke tests for tailscale...

  [PASS] tailscale binary responds (1.90.2)
  [PASS] tailscaled is active
  [PASS] Daemon socket responsive (state: NeedsLogin)
         Not connected — run 'sudo tailscale up' to join a tailnet

[aparece] All smoke tests passed for tailscale.
```

## Documentation

`README.md` gains a row in the app table:

| App | Description | Port(s) | Service |
|-----|-------------|---------|---------|
| tailscale | Tailscale mesh VPN | 41641/udp | tailscaled |

and entries for `tailscale.yml` and `roles/tailscale/` in the project structure block.

## Testing

Per `AGENTS.md`, Ansible roles cannot be run or tested on macOS. Verification happens on an Ubuntu 24.04 target:

1. `sudo aparece activate tailscale` — installs cleanly, smoke tests pass, notes print last
2. `sudo aparece activate tailscale` again — idempotent, no changed tasks beyond apt cache
3. `sudo tailscale up` — completes login, node appears in the admin console
4. `sudo aparece test tailscale` — now reports `Running` with the tailnet IP
5. `sudo ufw status` — shows `41641/udp ALLOW`
6. Reboot — node rejoins the tailnet with no intervention

## Scope Boundaries

- No auth keys, OAuth clients, or unattended enrollment. Login is interactive.
- No `tailscale serve` / `funnel`, exit-node configuration, subnet routing, or the IP forwarding sysctls those require.
- No Tailscale SSH. The security role's port 22 rule already covers SSH over the tailnet.
- No `ufw allow in on tailscale0`. Services keep their existing exposure; adding it would make every listening port tailnet-reachable, which is broader than this change intends.
- No changes to `bootstrap.yml`, the security role, or any other app's metadata.
- `aparece status tailscale` reports `ACTIVE` whenever tailscaled is running, including when the node is logged out and connected to nothing. Accurate reporting needs per-app status hooks — a change to the shared metadata contract beyond this feature's scope. The smoke test is the place that reports real connection state.
