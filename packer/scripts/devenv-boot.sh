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
