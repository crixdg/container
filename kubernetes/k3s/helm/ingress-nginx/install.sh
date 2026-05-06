#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx

# Label the first node as an ingress node if none are labelled yet
if ! kubectl get nodes -l ingress=true --no-headers 2>/dev/null | grep -q .; then
  FIRST_NODE=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -1)
  echo "No node labelled ingress=true. Labelling $FIRST_NODE ..."
  kubectl label node "$FIRST_NODE" ingress=true
fi

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -f "$SCRIPT_DIR/helm-values.yaml" \
  -n ingress-nginx --create-namespace \
  --wait --timeout 3m

echo "ingress-nginx installed. IngressClass 'nginx' is now the default."
