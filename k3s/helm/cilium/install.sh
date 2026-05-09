#!/bin/bash
# Install Cilium on a k3s cluster.
#
# Usage:
#   bash k3s/helm/cilium/install.sh <FIRST_SERVER_IP>
#
# Prerequisites:
#   - k3s servers deployed with flannel-backend=none and disable-network-policy=true
#   - kubectl pointing at the cluster (export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)
#   - helm 3 installed

set -euo pipefail

FIRST_SERVER_IP="${1:?Usage: $0 <FIRST_SERVER_IP>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.16.6"   # pin — update deliberately

helm repo add cilium https://helm.cilium.io 2>/dev/null || true
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version "$VERSION" \
  -f "$SCRIPT_DIR/helm-values.yml" \
  --set k8sServiceHost="$FIRST_SERVER_IP" \
  --set k8sServicePort=6443 \
  -n kube-system \
  --wait --timeout 5m

echo ""
echo "Cilium installed. Verify with:"
echo "  cilium status"
echo "  kubectl get pods -n kube-system -l k8s-app=cilium"
