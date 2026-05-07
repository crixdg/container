#!/bin/bash

# Install all production-essential components in dependency order:
#   1. cert-manager  (other charts may depend on it for TLS)
#   2. ingress-nginx
#   3. Longhorn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/../helm"

echo "==> [1/3] cert-manager"
bash "$HELM_DIR/cert-manager/install.sh"

echo "==> [2/3] ingress-nginx"
bash "$HELM_DIR/ingress-nginx/install.sh"

echo "==> [3/3] Longhorn"
bash "$HELM_DIR/longhorn/install.sh"

echo ""
K3S_BIN="${K3S_BIN_DIR:-/usr/local/bin}/k3s"

echo "All essentials installed. Cluster status:"
"$K3S_BIN" kubectl get nodes -o wide
echo ""
"$K3S_BIN" kubectl get pods -A | grep -E 'cert-manager|ingress-nginx|longhorn' || true
