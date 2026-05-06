#!/bin/bash
# Install all production-essential components in dependency order:
#   1. cert-manager  (other charts may depend on it for TLS)
#   2. ingress-nginx
#   3. Longhorn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/3] cert-manager"
bash "$SCRIPT_DIR/cert-manager/install.sh"

echo "==> [2/3] ingress-nginx"
bash "$SCRIPT_DIR/ingress-nginx/install.sh"

echo "==> [3/3] Longhorn"
bash "$SCRIPT_DIR/longhorn/install.sh"

echo ""
echo "All essentials installed. Cluster status:"
kubectl get nodes -o wide
echo ""
kubectl get pods -A | grep -E 'cert-manager|ingress-nginx|longhorn' || true
