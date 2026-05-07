#!/bin/bash

set -euo pipefail

# Join a worker node to an existing k3s server.
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

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
  if [ -f /etc/debian_version ]; then
    OS_FAMILY="debian"
  elif [ -f /etc/redhat-release ]; then
    OS_FAMILY="rhel"
  else
    echo "Error: unsupported OS. Supported: Debian/Ubuntu, RHEL/Rocky/AlmaLinux."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Install prerequisites
# ---------------------------------------------------------------------------
install_deps() {
  echo "Installing dependencies ($OS_FAMILY) ..."
  if [ "$OS_FAMILY" = "debian" ]; then
    apt-get update -qq
    apt-get install -y curl iptables nfs-common open-iscsi
    systemctl enable --now iscsid || true
  else
    dnf install -y curl iptables nfs-utils iscsi-initiator-utils
    systemctl enable --now iscsid || true

    if command -v getenforce &>/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
      echo "SELinux is Enforcing — installing k3s-selinux policy ..."
      if ! rpm -q k3s-selinux &>/dev/null; then
        dnf install -y https://rpm.rancher.io/k3s/latest/common/centos/8/noarch/k3s-selinux-1.4-1.el8.noarch.rpm || \
          dnf install -y k3s-selinux
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Load .env (optional — only K3S_VERSION is used)
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

if [ -n "${K3S_VERSION:-}" ]; then
  export INSTALL_K3S_VERSION="$K3S_VERSION"
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
detect_os
install_deps

echo "Joining worker to $K3S_SERVER_URL ..."
curl -sfL https://get.k3s.io | sh -s - agent

echo "Agent installed. Verify on the server with: kubectl get nodes"
