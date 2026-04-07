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
