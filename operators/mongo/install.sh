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

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MONGO_MODE="${MONGO_MODE:-standalone}"
OPERATOR_NAMESPACE="mongodb-operator"
NAMESPACE="mongodb"

if [ -z "$MONGO_PASSWORD" ]; then
  # Check if secret already exists; only fail on first install
  if ! kubectl get secret mongo-admin-password -n "$NAMESPACE" &>/dev/null; then
    echo "ERROR: MONGO_PASSWORD is required on first install." >&2
    echo "  MONGO_PASSWORD=<secret> ./install.sh" >&2
    exit 1
  fi
fi

# 1. Install the operator via Helm (idempotent)
helm repo add mongodb https://mongodb.github.io/helm-charts 2>/dev/null || true
helm repo update mongodb

helm upgrade --install mongodb-community-operator mongodb/community-operator \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NAMESPACE" --create-namespace --wait

echo "Operator ready in namespace: $OPERATOR_NAMESPACE"

# 2. Create the mongodb namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Create admin password secret
if [ -n "$MONGO_PASSWORD" ]; then
  kubectl create secret generic mongo-admin-password \
    --from-literal=password="$MONGO_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret mongo-admin-password created/updated in namespace: $NAMESPACE"
fi

# 4. Apply the MongoDB CR
case "$MONGO_MODE" in
  replicaset)
    kubectl apply -f "$SCRIPT_DIR/mongo-replicaset.yml"
    echo "MongoDB 3-member ReplicaSet applied."
    echo "Watch status:  kubectl get mongodbcommunity -n $NAMESPACE"
    echo "Connect (internal): mongo-svc.$NAMESPACE.svc.cluster.local:27017"
    echo "Connection string:  mongodb://admin:<password>@mongo-svc.$NAMESPACE.svc.cluster.local:27017/admin?replicaSet=mongo"
    ;;
  standalone|*)
    kubectl apply -f "$SCRIPT_DIR/mongo.yml"
    echo "MongoDB standalone (1-member ReplicaSet) applied."
    echo "Watch status:  kubectl get mongodbcommunity -n $NAMESPACE"
    echo "Connect: kubectl exec -it mongo-0 -n $NAMESPACE -- mongosh -u admin -p \$MONGO_PASSWORD"
    echo "Connection string: mongodb://admin:<password>@mongo-svc.$NAMESPACE.svc.cluster.local:27017/admin?replicaSet=mongo"
    ;;
esac
