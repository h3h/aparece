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
    │   └── nginx.yml
    └── roles/
        ├── base/                   # Essential packages, locale
        ├── security/               # SSH, UFW, fail2ban, sysctl
        ├── python/
        ├── ruby/
        ├── duckdb/
        ├── postgresql/
        ├── redis/
        ├── awscli/
        └── nginx/
```
