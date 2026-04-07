#!/bin/bash
set -euo pipefail

echo "=== devenv: reading cloud-init user-data ==="

# Read secrets from cloud-init instance metadata and build JSON extra-vars
EXTRA_VARS=$(python3 -c "
import json, subprocess, sys, yaml

try:
    userdata = subprocess.check_output(['cloud-init', 'query', 'userdata'], text=True)
    data = yaml.safe_load(userdata) or {}
except Exception:
    data = {}

v = {}
k = data.get('tailscale_auth_key', '')
if k: v['tailscale_auth_key'] = k
k = data.get('ssh_authorized_keys', '')
if k: v['ssh_authorized_keys'] = k
print(json.dumps(v))
")

echo "=== devenv: running ansible provisioning ==="

ansible-playbook /etc/ansible/devenv/local.yml \
  -i /etc/ansible/devenv/inventory/localhost.ini \
  --extra-vars "$EXTRA_VARS"

echo "=== devenv: provisioning complete ==="
