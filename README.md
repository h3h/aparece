# Aparece

A CLI tool for bootstrapping Ubuntu 24.04 cloud servers into a hardened,
ready-to-use configuration.

## Usage

```bash
./aparece <host> [options]
```

**Arguments:**
- `<host>` - Target host IP or hostname (required)

**Options:**
- `-u, --user USER` - SSH username (default: current user)
- `-k, --key PATH` - Path to SSH private key (default: `~/.ssh/id_rsa`)
- `-c, --check` - Run in dry-run mode
- `-v, --verbose` - Enable verbose output

**Examples:**
```bash
./aparece 192.168.1.100
./aparece myserver.example.com --user admin
./aparece 10.0.0.5 -u ubuntu -k ~/.ssh/cloud_key
```

## What Gets Installed

**Development Tools:**
- Python 3.12 (via deadsnakes PPA)
- Ruby (latest stable via rbenv)
- DuckDB (latest from GitHub releases)
- PostgreSQL 17 (localhost only)
- Redis (localhost only)
- AWS CLI v2

**Security Hardening:**
- SSH hardened (key-only auth, no root login, rate limiting)
- UFW firewall enabled (SSH only by default)
- fail2ban protecting SSH from brute force
- Automatic security updates (unattended-upgrades)
- Kernel security parameters via sysctl
- Unnecessary services disabled

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

## How It Works

1. **SSH Connection** - The CLI verifies SSH connectivity to the target host
2. **File Transfer** - Copies the `ansible/` directory to the remote machine via
   rsync
3. **Ansible Installation** - Installs Ansible on the remote host if not already
   present
4. **Local Execution** - Runs `ansible-playbook` locally on the target machine
   (no Ansible required on your machine)
5. **Cleanup** - Removes the temporary ansible directory from the remote host

This "push-to-pull" approach means you only need bash, SSH, and rsync locally.
All the heavy lifting happens on the target VM.

## Project Structure

```
aparece/
├── aparece                     # CLI entry point
└── ansible/
    ├── ansible.cfg
    ├── inventory/hosts.yml
    ├── playbooks/bootstrap.yml
    └── roles/
        ├── security/           # SSH, UFW, fail2ban, sysctl
        ├── base/               # Essential packages, locale
        ├── python/
        ├── ruby/
        ├── duckdb/
        ├── postgresql/
        ├── redis/
        └── awscli/
```

## Running Individual Roles

Use Ansible tags to run specific parts:

```bash
# After SSH'ing to the target and with ansible directory present:
ansible-playbook playbooks/bootstrap.yml --tags python
ansible-playbook playbooks/bootstrap.yml --tags security,base
```
