# Remote Development Environment — Design Spec

## Overview

A portable, barebones remote development environment accessed from iPad via Blink Shell over Tailscale SSH/mosh. Ubuntu 24.04 base with a single Ansible playbook that provisions everything at container/instance startup. Deployable as a Docker image (k8s) and Packer machine image (EC2/other providers).

## Key Decisions

- **Provisioning**: Single Ansible playbook, runs at startup (not build time)
- **Base image**: Ubuntu 24.04
- **Process management**: s6-overlay (Docker), systemd (EC2/Packer)
- **Network access**: Tailscale-only SSH, no public ports
- **Secrets**: Injected at deploy time via env vars (k8s Secrets, cloud-init user-data) — never baked into images
- **Persistence**: Home directory volume mount (k8s) or EBS (EC2) — convenient, not critical
- **Tool management**: Add Ansible roles over time, restart container or rebuild image to apply

## Project Structure

```
devenv/
├── ansible/
│   ├── local.yml              # Single playbook, runs at startup
│   ├── inventory/localhost.ini # localhost connection: local
│   ├── roles/
│   │   ├── base/              # Core packages: curl, wget, git, mosh, ca-certificates, locale
│   │   ├── user/              # Dev user creation, sudo, home dir, default shell
│   │   ├── ssh/               # sshd hardening + authorized_keys from extra-vars
│   │   ├── tailscale/         # Install Tailscale + tailscale up from extra-vars
│   │   └── s6/                # Install s6-overlay, service definitions
│   └── vars/main.yml          # Structural config: username, packages — no secrets
├── docker/
│   └── Dockerfile             # Ubuntu 24.04 + Ansible + playbook copied in, nothing else
├── packer/
│   └── devenv.pkr.hcl         # Packer template using Ansible provisioner
└── scripts/
    └── entrypoint.sh          # Runs ansible-playbook with extra-vars, hands off to s6
```

## Dockerfile

The image is minimal — Ubuntu + Ansible + the playbook. No provisioning at build time.

```
Layer 1: apt-get update && apt-get install -y ansible
Layer 2: COPY ansible/ /etc/ansible/devenv/
Layer 3: COPY scripts/entrypoint.sh /entrypoint.sh
         ENTRYPOINT ["/entrypoint.sh"]
```

All provisioning happens at startup via the entrypoint.

## Ansible Playbook

### local.yml

- Targets `localhost` with `connection: local`
- Applies roles in order: `base` → `user` → `ssh` → `tailscale` → `s6`
- Secrets passed via `--extra-vars` at runtime

### Roles

**base**
- `apt update`, install: `curl`, `wget`, `git`, `mosh`, `ca-certificates`
- Set locale to `en_US.UTF-8`
- Clean apt cache

**user**
- Create user with configurable username (default: `dev`)
- Add to `sudo` group, passwordless sudo
- Set default shell to `bash`
- Create home directory structure

**ssh**
- Disable password authentication
- Disable root login
- Key-only authentication
- Write authorized keys from `ssh_authorized_keys` extra-var to `~/.ssh/authorized_keys`
- Listen on port 22 (Tailscale handles the network boundary)

**tailscale**
- Install Tailscale from official repo
- Run `tailscale up --auth-key=$tailscale_auth_key --ssh`
- In Docker: start `tailscaled` daemon directly
- On EC2: enable systemd service

**s6** (Docker only, skipped on EC2 via `when` conditional)
- Install s6-overlay
- Define service directories under `/etc/s6-overlay/s6-rc.d/`
- Services: `tailscaled`, `sshd`
- Startup ordering: tailscaled → tailscale up → sshd

### vars/main.yml

```yaml
dev_username: dev
dev_shell: /bin/bash
base_packages:
  - curl
  - wget
  - git
  - mosh
  - ca-certificates
```

No secrets in this file.

## Entrypoint (Docker)

```
1. Read TAILSCALE_AUTH_KEY and SSH_AUTHORIZED_KEYS from environment variables
2. Run: ansible-playbook /etc/ansible/devenv/local.yml \
     -e "tailscale_auth_key=$TAILSCALE_AUTH_KEY" \
     -e "ssh_authorized_keys=$SSH_AUTHORIZED_KEYS"
3. Hand off to s6-overlay (exec /init)
```

Ansible is idempotent — first boot installs everything, subsequent restarts skip what's already done.

## Packer Template

- Source: Ubuntu 24.04 AMI (or equivalent for other providers)
- Provisioner: Shell — installs Ansible, copies playbook to `/etc/ansible/devenv/` (same as Dockerfile, no playbook run at build time)
- At boot: systemd service runs `ansible-playbook /etc/ansible/devenv/local.yml --extra-vars` with secrets from cloud-init user-data
- Same playbook, same startup-only provisioning model, different init system (systemd vs s6)

## Secret Injection

### Kubernetes
Kubernetes Secrets exposed as environment variables in the pod spec:
- `TAILSCALE_AUTH_KEY` — from a k8s Secret
- `SSH_AUTHORIZED_KEYS` — from a k8s Secret

Entrypoint reads env vars and passes to Ansible.

### EC2 / Cloud Providers
Cloud-init user-data provides secrets at instance launch:
- Passed by Terraform/Pulumi from a secret store (SSM, Secrets Manager)
- A systemd service reads the values and passes to `ansible-playbook --extra-vars`

### Never Baked In
Images contain zero secrets. The same image works across environments with different credentials.

## Process Management

### Docker — s6-overlay
- s6-overlay runs as PID 1
- Manages: `tailscaled`, `sshd`
- Startup ordering enforced via s6 dependencies
- Automatic restart on crash
- Proper signal forwarding and graceful shutdown
- Future-proof for adding chromium, claude code, etc.

### EC2 — systemd
- Standard systemd units for `tailscaled` and `sshd`
- `After=` dependencies for ordering
- `Restart=on-failure` for resilience

## Persistence

- **k8s**: Home directory mounted as a PersistentVolumeClaim
- **EC2**: Home directory on EBS volume
- Contents: working directories, shell history, caches
- If lost: no big deal, everything important is in git or can be reprovisioned

## Adding Tools Over Time

1. Create a new Ansible role (e.g., `roles/neovim/`)
2. Add it to `local.yml`
3. Either:
   - SSH in and run `ansible-playbook local.yml` directly (immediate, no rebuild)
   - Restart the container (entrypoint re-runs Ansible, picks up new role)
   - Rebuild the image (bakes the role into a fresh image for clean deploys)

## Future Additions (Out of Scope for Now)

- Dotfiles management (will be added incrementally)
- Headless Chromium / Playwright (planned, s6 will manage the process)
- Claude Code (planned, s6 will manage the process)
- Additional language runtimes and tools (added as Ansible roles)
