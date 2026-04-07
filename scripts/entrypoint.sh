#!/bin/bash
set -euo pipefail

echo "=== devenv: running ansible provisioning ==="

# Build extra-vars as JSON to handle multi-line values safely
EXTRA_VARS="{}"

if [ -n "${TAILSCALE_AUTH_KEY:-}" ] || [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
  EXTRA_VARS=$(python3 -c "
import json, os
v = {}
k = os.environ.get('TAILSCALE_AUTH_KEY', '')
if k: v['tailscale_auth_key'] = k
k = os.environ.get('SSH_AUTHORIZED_KEYS', '')
if k: v['ssh_authorized_keys'] = k
print(json.dumps(v))
")
fi

ansible-playbook /etc/ansible/devenv/local.yml \
  -i /etc/ansible/devenv/inventory/localhost.ini \
  --extra-vars "$EXTRA_VARS"

echo "=== devenv: provisioning complete, starting s6 ==="

exec /init
