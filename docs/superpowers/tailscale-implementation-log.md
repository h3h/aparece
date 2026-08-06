# Tailscale Implementation — Decisions & Doubts Log

Working log for the autonomous implementation of
`docs/superpowers/specs/2026-08-05-tailscale-design.md`.

Each entry is either a **DECISION** (resolved, with reasoning) or a **DOUBT**
(unresolved, needs human or later verification). Doubts that remain open at the
end are escalated for review.

---

## Environment constraints (established before work began)

**DECISION — E1.** No Ubuntu target is available. Per `AGENTS.md`, Ansible roles
cannot be run or tested on macOS/Darwin. All 16 verification steps in the spec's
Testing section are therefore *unexecuted*. Local verification is limited to
static checks: `bash -n`, shellcheck (if installable), and YAML parse via
`python3 -c 'yaml.safe_load'`. This is a known, spec-acknowledged limitation,
not a shortcut taken during implementation. Every claim of "works" in the final
report must be scoped to static checks only.

**DECISION — E2.** Commit signing is enabled (`commit.gpgsign=true`,
`gpg.format=ssh`, key `~/.ssh/id_rsa.pub`). The user instructed not to interrupt
for anything requiring a key. Two prior commits in this session
(`498581c`, `b4be8e5`) signed without prompting, so the key is available
non-interactively via agent/keychain. Signing is left ON. If any commit blocks
on a passphrase, fall back to `--no-gpg-sign` and record it here.

---

## Log

**DECISION — L1.** Installed `shellcheck` via Homebrew (0.11.0). The repo had no
linters available and this feature adds two shell scripts, one of which can lock
a user out of a server. Static analysis was worth the one-time system change.

**DOUBT — L2 (partially resolved). Does a Tailscale SSH session's process
ancestry actually contain `tailscaled`?** This is the single assumption the
entire lockdown safety argument rests on. Research finding: tailscaled spawns
SSH sessions as child processes of itself, re-executing its own binary with a
`be-child ssh` subcommand (the "incubator" privilege-separation model). The
incubator therefore has `comm` = `tailscaled`, and it sits between the session
shell and the daemon, so an ancestry walk should encounter it.

Confidence: reasonably high but NOT verified on a live host. The strongest
source is a third-party auto-generated wiki of the tailscale source, not
official documentation. **Must be confirmed on a real Ubuntu 24.04 host before
relying on the lockdown** — see the verification command in the Handoff section.

Failure mode if wrong: the gate refuses to prompt (fails closed). Annoying, not
dangerous.

**DOUBT — L3. `comm` is truncated to 15 characters, and OpenSSH ≥ 9.8 renames
per-session processes to `sshd-session`.** Ubuntu 24.04 ships OpenSSH 9.6, whose
per-session process is still `sshd`, so the sshd-over-tailnet branch of the gate
should match today. If a future point release moves to 9.8+, that branch stops
matching and the prompt silently stops appearing for sshd sessions. Fails
closed, so it degrades safely, but it will look like a mysterious regression.
Neither `tailscaled` (10 chars) nor `sshd` (4) is affected by the 15-char
truncation itself. Mitigated in the implementation by accepting both names
(see L13).

**DECISION — L5 (doubt resolved).** Verified against the `tailscale.com/ipn/ipnstate`
Go package documentation that `tailscale status --json` has a top-level
`BackendState` string whose documented values are exactly `NoState`,
`NeedsLogin`, `NeedsMachineAuth`, `Stopped`, `Starting`, `Running` — matching
the spec's enumeration. `TailscaleIPs` (`[]netip.Addr`) exists both at the top
level and on `Self`. The spec's `TailscaleIPs[0]` reference is correct as a
top-level lookup. Note `NeedsMachineAuth` was missing from the spec's list of
non-Running states; it is covered anyway because the scripts treat "anything
other than Running" as not-connected.

**DECISION — L6. The spec's own `notes` snippet was a latent bug; the
implementation deviates from it deliberately.** The spec specified:

    [[ -n "$notes" ]] && { echo ""; echo "$notes"; }

as the last statement of `cmd_activate`. Under `set -euo pipefail` this returns
1 when `notes` is empty (the failing `[[ ]]` is the left operand of `&&`, so
`set -e` does not fire, but the compound list's status is 1 and becomes the
function's return value). The call site `cmd_activate "$2"` inside the `case` is
an unprotected simple command, so `set -e` fires there and the script exits 1.

Net effect had this shipped: `aparece activate` would have exited non-zero for
all ten existing apps — every app without a `notes` field. This was verified
empirically, not merely reasoned about: the buggy variant exits 1, the shipped
`if`-statement variant exits 0.

Resolution: use an `if` block. An `if` with a false condition and no `else`
exits 0, so no trailing `true` guard is needed. **The spec must be corrected**
so the erroneous snippet is not copied by a future reader.

**DECISION — L7.** Confirmed empirically that a `notes: |` block scalar
round-trips through the existing `parse_meta` unchanged: it loads as a Python
`str`, takes the `else: print(val)` branch, and the only delta is one trailing
newline that `$( )` strips anyway. Interior blank lines and indentation survive.
No change to `parse_meta` was needed — the spec's claim here was correct.

**DECISION — L8. Pre-existing doc drift left alone.** `bun` has an
`app_metadata/bun.yml` and a `roles/bun/` on disk but appears in neither the
README's app table nor its project-structure tree. This predates the Tailscale
work and is out of scope; fixing it would mix unrelated changes into this
feature's diff. Flagging it here so it is a known gap rather than an oversight.

**DECISION — L9 (doubt resolved; spec was wrong).** The spec asserted that
`tailscale status --json` "exits non-zero when the node is logged out." Read the
actual source of `runStatus` in `cmd/tailscale/cli/status.go`: the `--json`
branch marshals the status, prints it, and `return nil`s **before** reaching the
`isRunningOrStarting()` check that would `os.Exit(1)`. So `--json` exits 0 even
when logged out.

This resolves the highest-stakes open doubt — whether check 3 of the smoke test
passes on a fresh, not-yet-connected node. It does: tailscaled is running, the
socket is reachable, and the JSON carries `BackendState: "NeedsLogin"`. Had this
gone the other way, every `aparece activate tailscale` would have failed its own
smoke test and stopped tailscaled.

The `|| true` in the test script is still correct and still needed — the CLI
*does* exit non-zero when the daemon socket is genuinely unreachable, which is
the failure this check exists to catch. Only the stated rationale was wrong. The
inaccurate comment has been corrected in `ansible/tests/tailscale.sh`, and the
spec needs the same correction.

**DECISION — L10.** `netip.Addr` marshals to a bare JSON string, confirming the
subagent's uncertain assumption that `TailscaleIPs` elements are strings rather
than objects. Its defensive handling (top-level first, then `Self`, first
element without a `:` rather than blind index 0) is kept — it is strictly more
robust than the spec's `TailscaleIPs[0]` and behaves identically when the usual
convention holds.

**DECISION — L11. Hardened gate 5 beyond the spec: BOTH ends of an sshd session
must be tailnet addresses, not just the client source.** The spec specified only
that `SSH_CONNECTION`'s source address be in 100.64.0.0/10. That is a proxy, not
proof: 100.64.0.0/10 is shared CGNAT space, so a client behind carrier-grade NAT
can legitimately present a source address in that range while connecting to the
host's PUBLIC address. Under the spec as written, that session would pass the
gate, and closing 22/tcp would cut the very session that authorised it — the
exact failure the gate exists to prevent.

Fix: also require `SSH_CONNECTION` field 3 (the local address the client
reached) to be a tailnet address. That proves the connection terminated on the
`tailscale0` interface. Verified by test: `100.90.1.2 54321 203.0.113.9 22` is
now refused, where the spec's check would have allowed it.

**DECISION — L12. Also accept Tailscale's IPv6 range `fd7a:115c:a1e0::/48`.**
The spec named only the IPv4 CGNAT range, so `ssh <tailnet-ipv6>` would have
been refused with a confusing message despite being a perfectly good tailnet
session. Matching is a fixed three-group prefix on a lowercased address.

**DECISION — L13. Kept the subagent's acceptance of `sshd-session` alongside
`sshd`** (see L3). It only distinguishes "is an SSH session" from "is not"; the
address checks do the actual gating, so this widens nothing meaningful and
prevents silent rot on OpenSSH ≥ 9.8.

**VERIFICATION — L14.** The gate script was exercised end-to-end against a
synthetic environment (fake `/proc` tree, stub `ufw`/`tailscale`/`systemctl`, a
pty driver): Tailscale SSH accept, sshd-over-tailnet accept with warning,
public-IP refusal, CGNAT-to-public-IP refusal, local console refusal,
`RunSSH:false`, `NeedsLogin`, non-TTY silence, bare-Enter declining, apply, and
silent idempotent re-run. All 11 exit 0; the rule is deleted only on `y`. The
address matcher was unit-tested against 24 addresses including octal-padding
traps (`100.070.0.1` → in range, `100.08.0.1` → out).

Integration of `tests/tailscale.sh` → `lib/secure-ssh.sh` was also exercised:
the fresh-install path produces output byte-identical to the spec's sample and
exits 0; an unreachable daemon socket correctly exits 1.

**This is simulation, not proof.** Every stub was written to match assumed CLI
behaviour. It validates the scripts' logic, not their agreement with real
`tailscale`, `ufw`, or Linux `/proc`.

**DOUBT — L4. `tailscale debug prefs` output shape is not a stability
guarantee.** Confirmed that `RunSSH` exists as a real field in the `ipn.Prefs`
struct and that checking `tailscale debug prefs` for `RunSSH: true` is the
common practice. Also confirmed the JSON marshaller omits unconfigured
preferences — so `RunSSH` may be ABSENT rather than `false` on a node that never
enabled SSH. The gate must treat absent as false, not as an error. Already
called out in the spec's scope boundaries as failing closed.


---

## Handoff: doubts still open at end of implementation

Nothing below was resolvable without an Ubuntu 24.04 host running real
Tailscale. All of it fails in the safe direction (the lockdown is not offered)
except where noted.

**H1 — `tailscaled` in process ancestry (from L2). HIGHEST PRIORITY.** The whole
safety argument for gate 5 assumes a Tailscale SSH session has an ancestor whose
`/proc/<pid>/comm` is exactly `tailscaled`. Supported by how the incubator works
(tailscaled re-execs itself), never observed on a live host. Verify first:

    tailscale ssh <host>
    pid=$$; while [ "$pid" -gt 1 ]; do \
      cat /proc/$pid/stat | sed 's/.*(\(.*\)).*/\1/'; \
      pid=$(awk '{print $4}' /proc/$pid/stat); done

Expect `tailscaled` in that list. If absent, Tailscale SSH sessions are refused
and only the sshd-over-tailnet path works.

**H2 — `tailscale debug prefs` shape (from L4).** `RunSSH` confirmed to exist in
`ipn.Prefs`, but the debug command's JSON is not a stability guarantee, and
unconfigured prefs may be omitted entirely rather than emitted as `false`. The
code treats absent as false. Confirm `tailscale debug prefs | grep RunSSH` after
`tailscale up --ssh`.

**H3 — `ufw status` output format.** Gate 2 matches the "To" column with
`^22/tcp( \(v6\))? +ALLOW`. Derived from the rule the security role creates
(`rule: allow, port: "22", proto: tcp`), never seen rendered. If it does not
match, the prompt never appears.

**H4 — `ufw delete allow 22/tcp` is non-interactive** and removes both the v4
and v6 rules. Believed true (only numbered deletes prompt). stdin is left
attached, so a prompt would be answerable rather than hanging.

**H5 — Scoped 22/tcp rules.** If a scoped rule (e.g. `ALLOW 192.168.1.0/24`)
coexists with the Anywhere rule, the delete removes only the Anywhere rule while
the script says "Public SSH is closed" — slightly overstated. Not a lockout
risk, and not a configuration this project's roles produce.

**H6 — The 16 verification steps in the spec's Testing section are entirely
unrun.** Ansible was never executed; the role has never installed anything. The
role is transcribed from Tailscale's documented install procedure and is the
least novel part of this work, but "never run" is the honest status.

**H7 — `tailscale version` line 1 is the bare version.** Assumed by the role's
`stdout_lines[0]` and the smoke test. Cosmetic only if wrong.

---

## Post-hoc addendum to E2 — commit signing

Signing FAILED at commit time: `error: 1Password: failed to fill whole buffer`
/ `fatal: failed to write commit object`. The configured SSH signer is 1Password,
which needs an interactive unlock. The earlier session commits (`498581c`,
`b4be8e5`) succeeded because the vault was still unlocked; it has since locked.

Per the standing instruction not to interrupt for commit signing or anything
requiring a key, the feature commits were made with `--no-gpg-sign`. **They are
unsigned and will show as unverified.** To re-sign after unlocking 1Password:

    git rebase --exec 'git commit --amend --no-edit -S' main

No other action was blocked by this.
