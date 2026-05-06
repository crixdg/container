#!/bin/bash

set -euo pipefail

# Join an additional worker node to an existing k3s server.
#
# Usage:
#   K3S_SERVER_URL=https://<server-ip>:6443 \
#   K3S_TOKEN=<node-token>                  \
#   bash install-agent.sh
#
# K3S_TOKEN is found on the server at: /var/lib/rancher/k3s/server/node-token

: "${K3S_SERVER_URL:?K3S_SERVER_URL must be set (e.g. https://192.168.1.100:6443)}"
: "${K3S_TOKEN:?K3S_TOKEN must be set (cat /var/lib/rancher/k3s/server/node-token on the server)}"

export K3S_URL="$K3S_SERVER_URL"
export K3S_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

if [ -n "${K3S_VERSION:-}" ]; then
  export INSTALL_K3S_VERSION="$K3S_VERSION"
fi

# ------- Install --------------------------------------------------------------

echo "Joining worker to $K3S_SERVER_URL ..."
curl -sfL https://get.k3s.io | sh -

echo "Agent installed. Verify on the server with: kubectl get nodes"
