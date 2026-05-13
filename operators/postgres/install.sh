#!/bin/bash

# CloudNativePG — operator install + Cluster CR apply
#
# Usage:
#   ./install.sh                    # single-instance Postgres (dev)
#   POSTGRES_MODE=ha ./install.sh   # 3-instance HA cluster (production)
#
# Optional env vars:
#   POSTGRES_MODE      — "standalone" (default) or "ha"
#   POSTGRES_PASSWORD  — app user password; required on first install

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

POSTGRES_MODE="${POSTGRES_MODE:-standalone}"
OPERATOR_NAMESPACE="cnpg-system"
NAMESPACE="postgres"

if [ -z "$POSTGRES_PASSWORD" ]; then
  if ! kubectl get secret postgres-app-password -n "$NAMESPACE" &>/dev/null; then
    echo "ERROR: POSTGRES_PASSWORD is required on first install." >&2
    echo "  POSTGRES_PASSWORD=<secret> ./install.sh" >&2
    exit 1
  fi
fi

# 1. Install the operator via Helm (idempotent)
helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
helm repo update cnpg

helm upgrade --install cnpg cnpg/cloudnative-pg \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NAMESPACE" --create-namespace --wait

echo "Operator ready in namespace: $OPERATOR_NAMESPACE"

# 2. Create the postgres namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Create app user password secret
if [ -n "$POSTGRES_PASSWORD" ]; then
  kubectl create secret generic postgres-app-password \
    --from-literal=password="$POSTGRES_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret postgres-app-password created/updated in namespace: $NAMESPACE"
fi

# 4. Apply the Cluster CR
case "$POSTGRES_MODE" in
  ha)
    kubectl apply -f "$SCRIPT_DIR/postgres-ha.yml"
    echo "PostgreSQL HA cluster (1 primary + 2 standbys) applied."
    echo "Watch status:  kubectl get cluster -n $NAMESPACE"
    echo "Primary svc:   postgres-rw.$NAMESPACE.svc.cluster.local:5432"
    echo "Read-only svc: postgres-ro.$NAMESPACE.svc.cluster.local:5432"
    echo "Connect:       kubectl cnpg psql postgres -n $NAMESPACE"
    ;;
  standalone|*)
    kubectl apply -f "$SCRIPT_DIR/postgres.yml"
    echo "PostgreSQL standalone applied."
    echo "Watch status:  kubectl get cluster -n $NAMESPACE"
    echo "Service:       postgres-rw.$NAMESPACE.svc.cluster.local:5432"
    echo "Connect:       kubectl cnpg psql postgres -n $NAMESPACE"
    ;;
esac
