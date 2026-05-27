#!/bin/bash

# CloudNativePG clusters are declared as CRs, not Helm releases.
# The operator (cnpg-system namespace) watches all namespaces and reconciles this resource.

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
NAMESPACE="postgres"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create the app user secret if it doesn't exist.
# Pass POSTGRES_PASSWORD as an environment variable — never commit the actual value.
if ! kubectl get secret postgres-app-secret -n "$NAMESPACE" > /dev/null 2>&1; then
  if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "Error: POSTGRES_PASSWORD environment variable is not set."
    exit 1
  fi
  kubectl create secret generic postgres-app-secret \
    --from-literal=username=app \
    --from-literal=password="$POSTGRES_PASSWORD" \
    -n "$NAMESPACE"
fi

kubectl apply -f "$SCRIPT_DIR/helm-values.yml" -n "$NAMESPACE"
echo "Cluster CR applied. Watch status with: kubectl get cluster -n $NAMESPACE"
