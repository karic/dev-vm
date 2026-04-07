# Remote Dev Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a portable remote dev environment provisioned by Ansible at startup, deployed as Docker image (k8s) and Packer machine image (EC2), accessed via iPad/Blink Shell over Tailscale SSH/mosh.

**Architecture:** Single Ansible playbook runs at container/instance startup (not build time). Docker image is just Ubuntu + Ansible + playbook. Secrets injected at deploy time via env vars. s6-overlay manages processes in Docker, systemd on EC2.

**Tech Stack:** Ansible, Docker, Packer, s6-overlay, Tailscale, Ubuntu 24.04

**Spec:** `docs/superpowers/specs/2026-04-07-remote-devenv-design.md`

---

## File Structure

```
ansible/
├── local.yml                              # Main playbook — applies all roles against localhost
├── inventory/localhost.ini                # Inventory: localhost with connection=local
├── vars/main.yml                          # Variables: username, shell, package list (no secrets)
├── roles/
│   ├── base/tasks/main.yml               # apt update, install core packages, set locale
│   ├── user/tasks/main.yml               # Create dev user, sudo, home dir
│   ├── ssh/tasks/main.yml                # Install openssh-server, harden sshd, write authorized_keys
│   ├── ssh/templates/sshd_config.j2      # Hardened sshd config template
│   ├── tailscale/tasks/main.yml          # Install tailscale, start daemon, join tailnet
│   └── s6/tasks/main.yml                 # Install s6-overlay, create service dirs
│       s6/files/sshd/run                 # s6 service script for sshd
│       s6/files/sshd/type                # s6 service type (longrun)
│       s6/files/tailscaled/run           # s6 service script for tailscaled
│       s6/files/tailscaled/type          # s6 service type (longrun)
│       s6/files/tailscale-up/run         # s6 oneshot to join tailnet
│       s6/files/tailscale-up/type        # s6 service type (oneshot)
│       s6/files/tailscale-up/up          # s6 oneshot up script
│       s6/files/tailscale-up/dependencies.d/tailscaled  # ordering
│       s6/files/sshd/dependencies.d/tailscale-up        # ordering
docker/
├── Dockerfile                             # Ubuntu 24.04, install ansible, copy playbook, set entrypoint
scripts/
├── entrypoint.sh                          # Read env vars, run ansible-playbook, exec s6 /init
packer/
├── devenv.pkr.hcl                         # Packer HCL template for AMI/other formats
├── scripts/setup.sh                       # Shell provisioner: install ansible, copy playbook
├── scripts/devenv-boot.sh                 # First-boot script: read cloud-init, run ansible
├── files/devenv-boot.service              # systemd unit for first-boot ansible run
```

---

## Task 1: Ansible Variables and Inventory

**Files:**
- Create: `ansible/vars/main.yml`
- Create: `ansible/inventory/localhost.ini`

- [ ] **Step 1: Create vars/main.yml**

```yaml
dev_username: dev
dev_shell: /bin/bash
base_packages:
  - curl
  - wget
  - git
  - mosh
  - ca-certificates
  - locales
  - openssh-server
  - sudo
```

- [ ] **Step 2: Create inventory/localhost.ini**

```ini
[local]
localhost ansible_connection=local
```

- [ ] **Step 3: Commit**

```bash
git add ansible/vars/main.yml ansible/inventory/localhost.ini
git commit -m "feat: add ansible variables and inventory"
```

---

## Task 2: Base Role

**Files:**
- Create: `ansible/roles/base/tasks/main.yml`

- [ ] **Step 1: Create base role tasks**

```yaml
---
- name: Update apt cache
  ansible.builtin.apt:
    update_cache: yes
    cache_valid_time: 3600

- name: Install base packages
  ansible.builtin.apt:
    name: "{{ base_packages }}"
    state: present

- name: Ensure en_US.UTF-8 locale exists
  community.general.locale_gen:
    name: en_US.UTF-8
    state: present

- name: Set default locale
  ansible.builtin.copy:
    dest: /etc/default/locale
    content: |
      LANG=en_US.UTF-8
      LC_ALL=en_US.UTF-8
    mode: "0644"

- name: Clean apt cache
  ansible.builtin.apt:
    autoclean: yes
```

- [ ] **Step 2: Test the role with ansible-playbook --syntax-check**

Create a temporary `ansible/local.yml` that only includes the base role:

```yaml
---
- hosts: localhost
  connection: local
  become: yes
  vars_files:
    - vars/main.yml
  roles:
    - base
```

Run:
```bash
ansible-playbook ansible/local.yml --syntax-check -i ansible/inventory/localhost.ini
```

Expected: `playbook: ansible/local.yml` (no errors)

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/base/tasks/main.yml ansible/local.yml
git commit -m "feat: add base role — core packages and locale"
```

---

## Task 3: User Role

**Files:**
- Create: `ansible/roles/user/tasks/main.yml`

- [ ] **Step 1: Create user role tasks**

```yaml
---
- name: Create dev user
  ansible.builtin.user:
    name: "{{ dev_username }}"
    shell: "{{ dev_shell }}"
    create_home: yes
    groups: sudo
    append: yes

- name: Allow passwordless sudo for dev user
  ansible.builtin.copy:
    dest: "/etc/sudoers.d/{{ dev_username }}"
    content: "{{ dev_username }} ALL=(ALL) NOPASSWD:ALL\n"
    mode: "0440"
    validate: "visudo -cf %s"

- name: Create .ssh directory
  ansible.builtin.file:
    path: "/home/{{ dev_username }}/.ssh"
    state: directory
    owner: "{{ dev_username }}"
    group: "{{ dev_username }}"
    mode: "0700"
```

- [ ] **Step 2: Add user role to local.yml**

```yaml
---
- hosts: localhost
  connection: local
  become: yes
  vars_files:
    - vars/main.yml
  roles:
    - base
    - user
```

- [ ] **Step 3: Run syntax check**

```bash
ansible-playbook ansible/local.yml --syntax-check -i ansible/inventory/localhost.ini
```

Expected: `playbook: ansible/local.yml` (no errors)

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/user/tasks/main.yml ansible/local.yml
git commit -m "feat: add user role — dev user with passwordless sudo"
```

---

## Task 4: SSH Role

**Files:**
- Create: `ansible/roles/ssh/tasks/main.yml`
- Create: `ansible/roles/ssh/templates/sshd_config.j2`

- [ ] **Step 1: Create sshd_config template**

```jinja2
# Managed by Ansible
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Authentication
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PubkeyAuthentication yes

# Security
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*

# Subsystems
Subsystem sftp /usr/lib/openssh/sftp-server
```

- [ ] **Step 2: Create ssh role tasks**

```yaml
---
- name: Deploy hardened sshd_config
  ansible.builtin.template:
    src: sshd_config.j2
    dest: /etc/ssh/sshd_config
    owner: root
    group: root
    mode: "0644"
    validate: "sshd -t -f %s"

- name: Ensure ssh host keys exist
  ansible.builtin.command:
    cmd: ssh-keygen -A
    creates: /etc/ssh/ssh_host_ed25519_key

- name: Write authorized_keys for dev user
  ansible.builtin.copy:
    dest: "/home/{{ dev_username }}/.ssh/authorized_keys"
    content: "{{ ssh_authorized_keys }}\n"
    owner: "{{ dev_username }}"
    group: "{{ dev_username }}"
    mode: "0600"
  when: ssh_authorized_keys is defined and ssh_authorized_keys | length > 0
```

- [ ] **Step 3: Add ssh role to local.yml**

```yaml
---
- hosts: localhost
  connection: local
  become: yes
  vars_files:
    - vars/main.yml
  roles:
    - base
    - user
    - ssh
```

- [ ] **Step 4: Run syntax check**

```bash
ansible-playbook ansible/local.yml --syntax-check -i ansible/inventory/localhost.ini
```

Expected: `playbook: ansible/local.yml` (no errors)

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/ssh/ ansible/local.yml
git commit -m "feat: add ssh role — hardened sshd with key-only auth"
```

---

## Task 5: Tailscale Role

**Files:**
- Create: `ansible/roles/tailscale/tasks/main.yml`

- [ ] **Step 1: Create tailscale role tasks**

```yaml
---
- name: Install Tailscale GPG key
  ansible.builtin.shell:
    cmd: curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
    creates: /usr/share/keyrings/tailscale-archive-keyring.gpg

- name: Add Tailscale apt repository
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main"
    filename: tailscale
    state: present

- name: Install Tailscale
  ansible.builtin.apt:
    name: tailscale
    state: present
    update_cache: yes

- name: Start tailscaled daemon (Docker)
  ansible.builtin.shell:
    cmd: tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
  when: ansible_virtualization_type == "docker"

- name: Enable tailscaled service (non-Docker)
  ansible.builtin.systemd:
    name: tailscaled
    enabled: yes
    state: started
  when: ansible_virtualization_type != "docker"

- name: Join tailnet
  ansible.builtin.shell:
    cmd: tailscale up --auth-key={{ tailscale_auth_key }} --ssh
  when: tailscale_auth_key is defined and tailscale_auth_key | length > 0
```

- [ ] **Step 2: Add tailscale role to local.yml**

```yaml
---
- hosts: localhost
  connection: local
  become: yes
  vars_files:
    - vars/main.yml
  roles:
    - base
    - user
    - ssh
    - tailscale
```

- [ ] **Step 3: Run syntax check**

```bash
ansible-playbook ansible/local.yml --syntax-check -i ansible/inventory/localhost.ini
```

Expected: `playbook: ansible/local.yml` (no errors)

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/tailscale/ ansible/local.yml
git commit -m "feat: add tailscale role — install and join tailnet"
```

---

## Task 6: s6-overlay Role

**Files:**
- Create: `ansible/roles/s6/tasks/main.yml`
- Create: `ansible/roles/s6/files/tailscaled/run`
- Create: `ansible/roles/s6/files/tailscaled/type`
- Create: `ansible/roles/s6/files/tailscale-up/type`
- Create: `ansible/roles/s6/files/tailscale-up/up`
- Create: `ansible/roles/s6/files/tailscale-up/dependencies.d/tailscaled` (empty file)
- Create: `ansible/roles/s6/files/sshd/run`
- Create: `ansible/roles/s6/files/sshd/type`
- Create: `ansible/roles/s6/files/sshd/dependencies.d/tailscale-up` (empty file)

- [ ] **Step 1: Create s6 service files for tailscaled (longrun)**

`ansible/roles/s6/files/tailscaled/type`:
```
longrun
```

`ansible/roles/s6/files/tailscaled/run`:
```bash
#!/command/execlineb -P
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock
```

- [ ] **Step 2: Create s6 service files for tailscale-up (oneshot)**

`ansible/roles/s6/files/tailscale-up/type`:
```
oneshot
```

`ansible/roles/s6/files/tailscale-up/up`:
```bash
#!/command/execlineb -P
foreground { tailscale up --auth-key=${TAILSCALE_AUTH_KEY} --ssh }
```

Create empty dependency marker:
`ansible/roles/s6/files/tailscale-up/dependencies.d/tailscaled` (empty file)

- [ ] **Step 3: Create s6 service files for sshd (longrun)**

`ansible/roles/s6/files/sshd/type`:
```
longrun
```

`ansible/roles/s6/files/sshd/run`:
```bash
#!/command/execlineb -P
/usr/sbin/sshd -D -e
```

Create empty dependency marker:
`ansible/roles/s6/files/sshd/dependencies.d/tailscale-up` (empty file)

- [ ] **Step 4: Create s6 role tasks**

```yaml
---
- name: Get system architecture
  ansible.builtin.set_fact:
    s6_arch: "{{ 'aarch64' if ansible_architecture == 'aarch64' else 'x86_64' }}"
  when: ansible_virtualization_type == "docker"

- name: Download s6-overlay noarch
  ansible.builtin.get_url:
    url: "https://github.com/just-containers/s6-overlay/releases/latest/download/s6-overlay-noarch.tar.xz"
    dest: /tmp/s6-overlay-noarch.tar.xz
    mode: "0644"
  when: ansible_virtualization_type == "docker"

- name: Download s6-overlay arch-specific
  ansible.builtin.get_url:
    url: "https://github.com/just-containers/s6-overlay/releases/latest/download/s6-overlay-{{ s6_arch }}.tar.xz"
    dest: "/tmp/s6-overlay-{{ s6_arch }}.tar.xz"
    mode: "0644"
  when: ansible_virtualization_type == "docker"

- name: Extract s6-overlay noarch
  ansible.builtin.shell:
    cmd: tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz
  when: ansible_virtualization_type == "docker"

- name: Extract s6-overlay arch-specific
  ansible.builtin.shell:
    cmd: "tar -C / -Jxpf /tmp/s6-overlay-{{ s6_arch }}.tar.xz"
  when: ansible_virtualization_type == "docker"

- name: Create s6 service directories
  ansible.builtin.file:
    path: "/etc/s6-overlay/s6-rc.d/{{ item }}"
    state: directory
    mode: "0755"
  loop:
    - tailscaled
    - tailscale-up
    - tailscale-up/dependencies.d
    - sshd
    - sshd/dependencies.d
  when: ansible_virtualization_type == "docker"

- name: Copy s6 service files
  ansible.builtin.copy:
    src: "{{ item.src }}"
    dest: "{{ item.dest }}"
    mode: "{{ item.mode }}"
  loop:
    - { src: "tailscaled/run", dest: "/etc/s6-overlay/s6-rc.d/tailscaled/run", mode: "0755" }
    - { src: "tailscaled/type", dest: "/etc/s6-overlay/s6-rc.d/tailscaled/type", mode: "0644" }
    - { src: "tailscale-up/type", dest: "/etc/s6-overlay/s6-rc.d/tailscale-up/type", mode: "0644" }
    - { src: "tailscale-up/up", dest: "/etc/s6-overlay/s6-rc.d/tailscale-up/up", mode: "0755" }
    - { src: "tailscale-up/dependencies.d/tailscaled", dest: "/etc/s6-overlay/s6-rc.d/tailscale-up/dependencies.d/tailscaled", mode: "0644" }
    - { src: "sshd/run", dest: "/etc/s6-overlay/s6-rc.d/sshd/run", mode: "0755" }
    - { src: "sshd/type", dest: "/etc/s6-overlay/s6-rc.d/sshd/type", mode: "0644" }
    - { src: "sshd/dependencies.d/tailscale-up", dest: "/etc/s6-overlay/s6-rc.d/sshd/dependencies.d/tailscale-up", mode: "0644" }
  when: ansible_virtualization_type == "docker"

- name: Add services to s6 user bundle
  ansible.builtin.file:
    path: "/etc/s6-overlay/s6-rc.d/user/contents.d/{{ item }}"
    state: touch
    mode: "0644"
  loop:
    - tailscaled
    - tailscale-up
    - sshd
  when: ansible_virtualization_type == "docker"

- name: Clean up s6 tarballs
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /tmp/s6-overlay-noarch.tar.xz
    - "/tmp/s6-overlay-{{ s6_arch }}.tar.xz"
  when: ansible_virtualization_type == "docker"
```

- [ ] **Step 5: Add s6 role to local.yml**

```yaml
---
- hosts: localhost
  connection: local
  become: yes
  vars_files:
    - vars/main.yml
  roles:
    - base
    - user
    - ssh
    - tailscale
    - s6
```

- [ ] **Step 6: Run syntax check**

```bash
ansible-playbook ansible/local.yml --syntax-check -i ansible/inventory/localhost.ini
```

Expected: `playbook: ansible/local.yml` (no errors)

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/s6/ ansible/local.yml
git commit -m "feat: add s6-overlay role — process supervision for Docker"
```

---

## Task 7: Entrypoint Script

**Files:**
- Create: `scripts/entrypoint.sh`

- [ ] **Step 1: Create entrypoint.sh**

```bash
#!/bin/bash
set -euo pipefail

echo "=== devenv: running ansible provisioning ==="

EXTRA_VARS=""

if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
  EXTRA_VARS="${EXTRA_VARS} tailscale_auth_key=${TAILSCALE_AUTH_KEY}"
fi

if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
  EXTRA_VARS="${EXTRA_VARS} ssh_authorized_keys=${SSH_AUTHORIZED_KEYS}"
fi

ansible-playbook /etc/ansible/devenv/local.yml \
  -i /etc/ansible/devenv/inventory/localhost.ini \
  ${EXTRA_VARS:+--extra-vars "$EXTRA_VARS"}

echo "=== devenv: provisioning complete, starting s6 ==="

exec /init
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/entrypoint.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "feat: add entrypoint — runs ansible then hands off to s6"
```

---

## Task 8: Dockerfile

**Files:**
- Create: `docker/Dockerfile`

- [ ] **Step 1: Create Dockerfile**

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ansible \
      python3 \
    && rm -rf /var/lib/apt/lists/*

COPY ansible/ /etc/ansible/devenv/
COPY scripts/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 2: Build the image (smoke test)**

```bash
docker build -f docker/Dockerfile -t devenv:local .
```

Expected: Image builds successfully. No provisioning runs — just copies files in.

- [ ] **Step 3: Commit**

```bash
git add docker/Dockerfile
git commit -m "feat: add Dockerfile — ubuntu + ansible + playbook"
```

---

## Task 9: Packer Template

**Files:**
- Create: `packer/devenv.pkr.hcl`
- Create: `packer/scripts/setup.sh`
- Create: `packer/scripts/devenv-boot.sh`
- Create: `packer/files/devenv-boot.service`

- [ ] **Step 1: Create the shell provisioner script**

`packer/scripts/setup.sh`:
```bash
#!/bin/bash
set -euo pipefail

# Install Ansible
apt-get update
apt-get install -y --no-install-recommends ansible python3
rm -rf /var/lib/apt/lists/*

# Copy playbook (Packer file provisioner puts it in /tmp/ansible)
mkdir -p /etc/ansible/devenv
cp -r /tmp/ansible/* /etc/ansible/devenv/
rm -rf /tmp/ansible

# Install first-boot service
cp /tmp/packer-files/devenv-boot.service /etc/systemd/system/devenv-boot.service
cp /tmp/packer-files/devenv-boot.sh /usr/local/bin/devenv-boot.sh
chmod +x /usr/local/bin/devenv-boot.sh
systemctl enable devenv-boot.service
```

- [ ] **Step 2: Create the first-boot script**

`packer/scripts/devenv-boot.sh`:
```bash
#!/bin/bash
set -euo pipefail

echo "=== devenv: reading cloud-init user-data ==="

# Read secrets from cloud-init instance metadata
TAILSCALE_AUTH_KEY=$(cloud-init query userdata | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('tailscale_auth_key',''))" 2>/dev/null || echo "")
SSH_AUTHORIZED_KEYS=$(cloud-init query userdata | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('ssh_authorized_keys',''))" 2>/dev/null || echo "")

EXTRA_VARS=""

if [ -n "${TAILSCALE_AUTH_KEY}" ]; then
  EXTRA_VARS="${EXTRA_VARS} tailscale_auth_key=${TAILSCALE_AUTH_KEY}"
fi

if [ -n "${SSH_AUTHORIZED_KEYS}" ]; then
  EXTRA_VARS="${EXTRA_VARS} ssh_authorized_keys=${SSH_AUTHORIZED_KEYS}"
fi

echo "=== devenv: running ansible provisioning ==="

ansible-playbook /etc/ansible/devenv/local.yml \
  -i /etc/ansible/devenv/inventory/localhost.ini \
  ${EXTRA_VARS:+--extra-vars "$EXTRA_VARS"}

echo "=== devenv: provisioning complete ==="
```

- [ ] **Step 3: Create the systemd unit**

`packer/files/devenv-boot.service`:
```ini
[Unit]
Description=DevEnv first-boot provisioning
After=cloud-init.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/devenv-boot.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Create the Packer template**

`packer/devenv.pkr.hcl`:
```hcl
packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

source "amazon-ebs" "devenv" {
  ami_name      = "devenv-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }

  ssh_username = "ubuntu"
}

build {
  sources = ["source.amazon-ebs.devenv"]

  provisioner "file" {
    source      = "../ansible"
    destination = "/tmp/ansible"
  }

  provisioner "file" {
    source      = "files/"
    destination = "/tmp/packer-files"
  }

  provisioner "file" {
    source      = "scripts/devenv-boot.sh"
    destination = "/tmp/packer-files/devenv-boot.sh"
  }

  provisioner "shell" {
    script = "scripts/setup.sh"
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  }
}
```

- [ ] **Step 5: Validate the Packer template**

```bash
cd packer && packer validate devenv.pkr.hcl; cd ..
```

Expected: `The configuration is valid.` (or a warning about missing plugins, which is fine without AWS creds)

- [ ] **Step 6: Commit**

```bash
git add packer/
git commit -m "feat: add packer template — AMI build with ansible + cloud-init boot"
```

---

## Task 10: Docker Build and Smoke Test

**Files:** None new — integration test of existing files.

- [ ] **Step 1: Build the Docker image**

```bash
docker build -f docker/Dockerfile -t devenv:test .
```

Expected: Image builds successfully.

- [ ] **Step 2: Run the container without secrets (verify entrypoint runs ansible)**

```bash
docker run --rm --privileged devenv:test 2>&1 | head -50
```

Expected: Ansible runs, installs packages. May fail at tailscale/s6 steps without proper environment — that's fine, this verifies the basic flow works.

- [ ] **Step 3: Verify ansible is present in the image**

```bash
docker run --rm --entrypoint ansible devenv:test --version
```

Expected: Ansible version output.

- [ ] **Step 4: Commit .gitignore**

Create a `.gitignore` to keep things clean:

```
*.retry
*.pyc
__pycache__/
.vagrant/
*.box
packer_cache/
```

```bash
git add .gitignore
git commit -m "chore: add gitignore"
```

---

## Self-Review

**Spec coverage check:**
- Base packages, locale: Task 2 (base role)
- Dev user, sudo, home dir: Task 3 (user role)
- sshd hardening, authorized_keys from extra-vars: Task 4 (ssh role)
- Tailscale install + join from extra-vars: Task 5 (tailscale role)
- s6-overlay, service definitions, startup ordering: Task 6 (s6 role)
- Dockerfile (Ubuntu + Ansible + copy, no build-time run): Task 8
- Entrypoint (read env, run ansible, exec s6): Task 7
- Packer template (shell provisioner, no build-time ansible run): Task 9
- Cloud-init secret injection for EC2: Task 9 (devenv-boot.sh)
- k8s secret injection via env vars: Task 7 (entrypoint.sh reads env)
- Persistence: Not a code artifact — handled at deploy time (PVC / EBS config)
- Adding tools over time: Covered by design — add role, update local.yml

**Placeholder scan:** No TBDs, TODOs, or vague steps found.

**Type/name consistency check:**
- `dev_username` used consistently across user, ssh roles and vars
- `tailscale_auth_key` and `ssh_authorized_keys` used consistently in roles, entrypoint.sh, devenv-boot.sh
- `TAILSCALE_AUTH_KEY` and `SSH_AUTHORIZED_KEYS` env var names consistent between entrypoint.sh and k8s secret injection
- s6 service names (`tailscaled`, `tailscale-up`, `sshd`) consistent between role files and dependencies
- Playbook path `/etc/ansible/devenv/local.yml` consistent across Dockerfile, entrypoint.sh, setup.sh, devenv-boot.sh
