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
