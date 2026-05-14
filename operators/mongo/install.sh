#!/bin/bash

# MongoDB Community Kubernetes Operator (MCK) — operator install + CR apply
#
# Usage:
#   ./install.sh                            # standalone MongoDB (1-member ReplicaSet, dev)
#   MONGO_MODE=replicaset ./install.sh      # 3-member ReplicaSet (HA)
#
# Optional env vars:
#   MONGO_MODE      — "standalone" (default) or "replicaset"
#   MONGO_PASSWORD  — admin password; required on first install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MONGO_MODE="${MONGO_MODE:-standalone}"
OPERATOR_NAMESPACE="mongodb-operator"
NAMESPACE="mongodb"

echo "==> Mode: $MONGO_MODE | MongoDB namespace: $NAMESPACE | Operator namespace: $OPERATOR_NAMESPACE"

if [ -z "${MONGO_PASSWORD:-}" ]; then
  if ! kubectl get secret mongo-admin-password -n "$NAMESPACE" &>/dev/null; then
    echo "ERROR: MONGO_PASSWORD is required on first install." >&2
    echo "  MONGO_PASSWORD=<secret> ./install.sh" >&2
    exit 1
  fi
fi

# 1. Install the operator via Helm (idempotent)
echo "==> Adding MongoDB Helm repo..."
helm repo add mongodb https://mongodb.github.io/helm-charts 2>/dev/null || true
helm repo update mongodb

# 2. Create the mongodb namespace
echo "==> Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing mongodb-community-operator..."
helm upgrade --install mongodb-community-operator mongodb/community-operator \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NAMESPACE" --create-namespace --wait

echo "==> Operator ready in namespace: $OPERATOR_NAMESPACE"

# 3. Create admin password secret
if [ -n "${MONGO_PASSWORD:-}" ]; then
  echo "==> Creating secret: mongo-admin-password"
  kubectl create secret generic mongo-admin-password \
    --from-literal=password="$MONGO_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# 4. Apply the MongoDB CR
case "$MONGO_MODE" in
  replicaset)
    echo "==> Applying MongoDB 3-member ReplicaSet..."
    kubectl apply -f "$SCRIPT_DIR/mongo-replicaset.yml"
    echo ""
    echo "MongoDB ReplicaSet applied. Useful commands:"
    echo "  Status:  kubectl get mongodbcommunity -n $NAMESPACE"
    echo "  Internal: mongo-svc.$NAMESPACE.svc.cluster.local:27017"
    echo "  Connect:  mongodb://admin:<password>@mongo-svc.$NAMESPACE.svc.cluster.local:27017/admin?replicaSet=mongo"
    ;;
  standalone|*)
    echo "==> Applying MongoDB standalone (1-member ReplicaSet)..."
    kubectl apply -f "$SCRIPT_DIR/mongo.yml"
    echo ""
    echo "MongoDB standalone applied. Useful commands:"
    echo "  Status:  kubectl get mongodbcommunity -n $NAMESPACE"
    echo "  Connect: kubectl exec -it mongo-0 -n $NAMESPACE -- mongosh -u admin -p \$MONGO_PASSWORD"
    echo "  Connect: mongodb://admin:<password>@mongo-svc.$NAMESPACE.svc.cluster.local:27017/admin?replicaSet=mongo"
    ;;
esac
