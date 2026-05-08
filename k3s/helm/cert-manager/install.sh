#!/bin/bash

set -euo pipefail

CERT_MANAGER_VERSION="v1.17.2"

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  -n cert-manager --create-namespace \
  --set crds.enabled=true \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=128Mi \
  --set webhook.resources.requests.cpu=10m \
  --set webhook.resources.requests.memory=32Mi \
  --set cainjector.resources.requests.cpu=10m \
  --set cainjector.resources.requests.memory=32Mi \
  --wait --timeout 3m

echo ""
echo "cert-manager installed."
echo ""
echo "Next: create a ClusterIssuer for Let's Encrypt."
echo "  For HTTP-01 (public domains):"
echo "    kubectl apply -f kubernetes/k3s/helm/cert-manager/letsencrypt-http01.yml"
echo "  For DNS-01 (private domains / wildcard):"
echo "    kubectl apply -f kubernetes/k3s/helm/cert-manager/letsencrypt-dns01.yml"
