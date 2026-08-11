# Aparece

A CLI tool for bootstrapping Ubuntu 24.04 cloud servers into a hardened,
ready-to-use configuration — then activating applications on demand.

## How It Works

Aparece operates in two phases:

1. **Bootstrap** (from your laptop) — Hardens a fresh server with security
   defaults and deploys the `aparece` CLI to the remote machine.
2. **Activate** (on the server) — Installs individual applications on demand,
   opens their firewall ports, and reports status.

### Bootstrap Phase

```bash
./aparece bootstrap [user@]host [options]
```

This connects via SSH, copies Ansible playbooks to the server, and runs the
bootstrap playbook which configures:

- Essential packages, locale, timezone
- SSH hardening (key-only auth, no root login, rate limiting)
- UFW firewall (SSH only by default)
- fail2ban protecting SSH from brute force
- Automatic security updates (unattended-upgrades)
- Kernel security parameters via sysctl

After bootstrap, the server has the `aparece` CLI at `/usr/local/bin/aparece`
and all application playbooks at `/opt/aparece/ansible/`.

### Activate Phase

SSH to the server and install applications as needed:

```bash
aparece list                      # See available apps
sudo aparece activate postgresql  # Install and activate an app
sudo aparece status               # Check what's running
```

Each activation installs the software, opens its firewall ports, and prints a
summary with the port, binary path, service name, and log locations.

## Bootstrap Options

**Arguments:**
- `[user@]host` - Target in SSH format (required)

**Options:**
- `-k, --key PATH` - Path to SSH private key (default: `~/.ssh/id_rsa`)
- `--create-user NAME` - Create a sudo user with this name
- `--set-hostname NAME` - Set the hostname on the remote machine
- `-c, --check` - Run in dry-run mode
- `-v, --verbose` - Enable verbose output

**Examples:**
```bash
./aparece bootstrap root@192.168.1.100
./aparece bootstrap admin@myserver.example.com --create-user myuser
./aparece bootstrap ubuntu@10.0.0.5 -k ~/.ssh/cloud_key --set-hostname webserver
```

## Available Applications

| App | Description | Port(s) | Service |
|-----|-------------|---------|---------|
| python | Python 3.12 via uv | — | — |
| ruby | Ruby via rbenv | — | — |
| duckdb | DuckDB CLI | — | — |
| postgresql | PostgreSQL 17 | 5432 | postgresql |
| redis | Redis server | 6379 | redis-server |
| awscli | AWS CLI v2 | — | — |
| nginx | Nginx web server | 80, 443 | nginx |
| tmux | tmux terminal multiplexer | — | — |
| chromium | Headless Chromium (Google Chrome stable) | — | — |
| tailscale | Tailscale mesh VPN | 41641/udp | tailscaled |

## Tailscale and SSH Lockdown

Activating `tailscale` installs the package, enables `tailscaled`, and opens
UDP 41641. It does not authenticate — login is interactive, so no auth keys are
passed through the CLI or stored on disk. Finish setup yourself:

```bash
sudo tailscale up --ssh
```

The `--ssh` flag enables Tailscale SSH, which is required before aparece will
offer the lockdown. Once the node is on the tailnet, running
`sudo aparece test tailscale` from a tailnet session offers to close public SSH
by deleting the UFW `22/tcp` rule.

The offer is gated on the current session already arriving over the tailnet —
either a Tailscale SSH session, or ordinary sshd reached at the `100.x` address.
Accepting it therefore cannot cut the connection running it. It defaults to no,
and does not appear on a non-interactive run or on a host that has no `22/tcp`
rule left to delete.

sshd keeps running and stays enabled, as a fallback. Note that while Tailscale
SSH is on, tailscaled owns port 22 on the tailnet address and shadows sshd — an
ordinary `ssh 100.x.y.z` is answered by tailscaled too. sshd takes over that port
only if you later turn Tailscale SSH off (`tailscale set --ssh=false`), which is
the recovery path if a tailnet ACL change ever breaks Tailscale SSH. Confirm access
from another device before ending the session; the cloud provider's serial or
web console is the out-of-band recovery path. To undo:

```bash
sudo ufw allow 22/tcp
```

Node keys expire after 180 days by default, which drops the host off the tailnet
and requires an interactive re-auth. Disable key expiry for the machine in the
Tailscale admin console — once public SSH is closed, the tailnet is the only way
in.

### UFW does not gate tailnet traffic

tailscaled inserts a `ts-input` iptables chain ahead of UFW's rules, containing a
blanket accept for the `tailscale0` interface. Every service listening on
`0.0.0.0` is therefore reachable from the tailnet at `100.x.y.z:<port>`
regardless of UFW rules — PostgreSQL, Redis, and nginx included. This is also
what keeps SSH working after port 22 is closed.

Installing Tailscale widens the reachable surface of the whole host, not just the
services aparece opens ports for. Bind anything that must stay off the tailnet to
`127.0.0.1`; the firewall will not do it.

## Requirements

**Local machine:**
- Bash 4+
- SSH client
- rsync

**Target machine:**
- Ubuntu 24.04 LTS
- SSH access with sudo privileges
- Your SSH key already authorized
- Internet connectivity

## Project Structure

```
aparece/
├── aparece                         # Local CLI entry point
├── templates/
│   └── aparece-remote.sh           # Remote CLI (deployed to /usr/local/bin/aparece)
└── ansible/
    ├── ansible.cfg
    ├── inventory/hosts.yml
    ├── playbooks/
    │   ├── bootstrap.yml           # Base + security (runs during bootstrap)
    │   └── activate.yml            # App activation (runs on server)
    ├── app_metadata/               # Per-app metadata (ports, paths, services)
    │   ├── python.yml
    │   ├── ruby.yml
    │   ├── duckdb.yml
    │   ├── postgresql.yml
    │   ├── redis.yml
    │   ├── awscli.yml
    │   ├── nginx.yml
    │   ├── tmux.yml
    │   ├── chromium.yml
    │   └── tailscale.yml
    ├── lib/
    │   └── secure-ssh.sh           # Gated public-SSH lockdown helper
    ├── tests/                      # Per-app smoke tests
    │   ├── postgresql.sh
    │   ├── redis.sh
    │   └── tailscale.sh
    └── roles/
        ├── base/                   # Essential packages, locale
        ├── security/               # SSH, UFW, fail2ban, sysctl
        ├── python/
        ├── ruby/
        ├── duckdb/
        ├── postgresql/
        ├── redis/
        ├── awscli/
        ├── nginx/
        ├── tmux/
        ├── chromium/
        └── tailscale/
```
