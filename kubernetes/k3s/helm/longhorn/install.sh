#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update longhorn

# ------- Basic-auth secret for the Longhorn UI ingress -----------------------

LONGHORN_NS=storage-controller
if ! kubectl get secret longhorn-basic-auth -n "$LONGHORN_NS" &>/dev/null; then
  echo "Creating basic-auth secret for Longhorn UI ..."
  read -rp "  Longhorn UI username: " LH_USER
  read -rsp "  Longhorn UI password: " LH_PASS
  echo
  kubectl create namespace "$LONGHORN_NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic longhorn-basic-auth \
    --from-literal=auth="$(htpasswd -nb "$LH_USER" "$LH_PASS")" \
    -n "$LONGHORN_NS"
fi

# ------- Install --------------------------------------------------------------

helm upgrade --install longhorn longhorn/longhorn \
  --version 1.9.0 \
  -f "$SCRIPT_DIR/helm-values.yaml" \
  -n storage-controller --create-namespace \
  --wait --timeout 5m

echo ""
echo "Longhorn installed. StorageClass 'longhorn' is available."
echo ""
echo "To make Longhorn the default (and remove local-path as default):"
echo "  bash $(dirname "$SCRIPT_DIR")/set-default-storageclass.sh"
