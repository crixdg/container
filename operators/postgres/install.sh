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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

POSTGRES_MODE="${POSTGRES_MODE:-standalone}"
OPERATOR_NAMESPACE="cnpg-system"
NAMESPACE="postgres"

echo "==> Mode: $POSTGRES_MODE | Postgres namespace: $NAMESPACE | Operator namespace: $OPERATOR_NAMESPACE"

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  if ! kubectl get secret postgres-app-password -n "$NAMESPACE" &>/dev/null; then
    echo "ERROR: POSTGRES_PASSWORD is required on first install." >&2
    echo "  POSTGRES_PASSWORD=<secret> ./install.sh" >&2
    exit 1
  fi
fi

# 1. Install the operator via Helm (idempotent)
echo "==> Adding CloudNativePG Helm repo..."
helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
helm repo update cnpg

echo "==> Installing cloudnative-pg operator..."
helm upgrade --install cnpg cnpg/cloudnative-pg \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NAMESPACE" --create-namespace --wait

echo "==> Operator ready in namespace: $OPERATOR_NAMESPACE"

# 2. Create the postgres namespace
echo "==> Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Create app user password secret
if [ -n "${POSTGRES_PASSWORD:-}" ]; then
  echo "==> Creating secret: postgres-app-password"
  kubectl create secret generic postgres-app-password \
    --from-literal=username="pg-admin" \
    --from-literal=password="$POSTGRES_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# 4. Apply the Cluster CR
case "$POSTGRES_MODE" in
  ha)
    echo "==> Applying PostgreSQL HA cluster (1 primary + 2 standbys)..."
    kubectl apply -f "$SCRIPT_DIR/postgres-ha.yml"
    echo ""
    echo "PostgreSQL HA applied. Useful commands:"
    echo "  Status:    kubectl get cluster -n $NAMESPACE"
    echo "  Primary:   postgres-rw.$NAMESPACE.svc.cluster.local:5432"
    echo "  Read-only: postgres-ro.$NAMESPACE.svc.cluster.local:5432"
    echo "  Connect:   kubectl cnpg psql postgres -n $NAMESPACE"
    ;;
  standalone|*)
    echo "==> Applying PostgreSQL standalone..."
    kubectl apply -f "$SCRIPT_DIR/postgres.yml"
    echo ""
    echo "PostgreSQL standalone applied. Useful commands:"
    echo "  Status:   kubectl get cluster -n $NAMESPACE"
    echo "  Service:  postgres-rw.$NAMESPACE.svc.cluster.local:5432"
    echo "  External: <NODE-IP>:30432"
    echo "  Connect:  kubectl cnpg psql postgres -n $NAMESPACE"
    ;;
esac
