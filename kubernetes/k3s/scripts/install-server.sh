#!/bin/bash

set -euo pipefail

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

    # k3s-selinux is required when SELinux is Enforcing
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
# Load .env
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found. Copy scripts/.env.server.example to scripts/.env and fill in your values."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${NODE_IP:?NODE_IP must be set in .env}"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
detect_os
install_deps

# ------- Build installer arguments ------------------------------------------

INSTALL_ARGS=(
  --node-ip "$NODE_IP"
  --cluster-cidr "${CLUSTER_CIDR:-10.42.0.0/16}"
  --service-cidr "${SERVICE_CIDR:-10.43.0.0/16}"
  --data-dir    "${DATA_DIR:-/var/lib/rancher/k3s}"
  --disable traefik
  --disable servicelb
)

TLS_SANS="$NODE_IP"
[ -n "${EXTRA_SANS:-}" ] && TLS_SANS="$TLS_SANS,$EXTRA_SANS"
INSTALL_ARGS+=(--tls-san "$TLS_SANS")

[ "${DISABLE_LOCAL_STORAGE:-false}" = "true" ] && INSTALL_ARGS+=(--disable local-storage)

# ------- Install ------------------------------------------------------------

INSTALL_K3S_EXEC="${INSTALL_ARGS[*]}"
export INSTALL_K3S_EXEC

if [ -n "${K3S_VERSION:-}" ]; then
  export INSTALL_K3S_VERSION="$K3S_VERSION"
fi

echo "Installing k3s server on $NODE_IP ..."
curl -sfL https://get.k3s.io | sh -

# ------- Wait for node Ready ------------------------------------------------

echo "Waiting for node to become Ready ..."
STATUS=""
for i in $(seq 1 60); do
  STATUS=$(/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get node \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "$STATUS" = "True" ]; then
    echo "Node is Ready."
    break
  fi
  echo "  attempt $i/60 — waiting 5s ..."
  sleep 5
done

if [ "$STATUS" != "True" ]; then
  echo "Node did not become Ready in time. Check: journalctl -u k3s -f"
  exit 1
fi

# ------- Summary ------------------------------------------------------------

echo ""
echo "------- k3s installed successfully --------------------------------------"
echo "Kubeconfig : /etc/rancher/k3s/k3s.yaml"
echo "Node token : $(cat /var/lib/rancher/k3s/server/node-token)"
echo ""
echo "To use kubectl from this host:"
echo "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo ""
echo "To use kubectl from a remote workstation:"
echo "  mkdir -p ~/.kube"
echo "  scp root@${NODE_IP}:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml"
echo "  sed -i 's/127.0.0.1/${NODE_IP}/g' ~/.kube/k3s.yaml"
echo "  export KUBECONFIG=~/.kube/k3s.yaml"
echo "-------------------------------------------------------------------------"
