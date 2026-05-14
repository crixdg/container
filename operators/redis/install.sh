#!/bin/bash

# Redis Operator (ot-container-kit) — operator install + CR apply
#
# Usage:
#   ./install.sh                         # standalone Redis (single-node)
#   REDIS_MODE=replication ./install.sh  # RedisReplication + RedisSentinel (HA)
#   REDIS_MODE=cluster ./install.sh      # RedisCluster (3 masters, 1 follower each)
#
# Optional env vars:
#   REDIS_MODE      — "standalone" (default), "replication", or "cluster"
#   REDIS_PASSWORD  — if set, creates a redis-secret in the redis namespace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REDIS_MODE="${REDIS_MODE:-standalone}"
OPERATOR_NAMESPACE="redis-operator"
NAMESPACE="redis"

echo "==> Mode: $REDIS_MODE | Redis namespace: $NAMESPACE | Operator namespace: $OPERATOR_NAMESPACE"

# 1. Install the operator via Helm (idempotent)
echo "==> Adding ot-container-kit Helm repo..."
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts --force-update
helm repo update ot-helm

echo "==> Installing redis-operator..."
helm upgrade --install redis-operator ot-helm/redis-operator \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NAMESPACE" --create-namespace --wait

echo "==> Operator ready in namespace: $OPERATOR_NAMESPACE"

# 2. Create the redis namespace
echo "==> Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Optionally create password secret
if [ -n "${REDIS_PASSWORD:-}" ]; then
  echo "==> Creating secret: redis-secret"
  kubectl create secret generic redis-secret \
    --from-literal=password="$REDIS_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    Remember to uncomment redisSecret in the CR YAML."
fi

# 4. Apply the Redis CR
case "$REDIS_MODE" in
  replication)
    echo "==> Applying RedisReplication + RedisSentinel..."
    kubectl apply -f "$SCRIPT_DIR/redis-replication.yml" -n "$NAMESPACE"
    kubectl apply -f "$SCRIPT_DIR/redis-sentinel.yml" -n "$NAMESPACE"
    echo ""
    echo "RedisReplication + RedisSentinel applied. Useful commands:"
    echo "  Status:  kubectl get redisreplication,redissentinel -n $NAMESPACE"
    echo "  Master:  redis-cli -p 26379 -h <sentinel-svc> sentinel get-master-addr-by-name mymaster"
    ;;
  cluster)
    echo "==> Applying RedisCluster (3 masters, 1 follower each)..."
    kubectl apply -f "$SCRIPT_DIR/redis-cluster.yml" -n "$NAMESPACE"
    echo ""
    echo "RedisCluster applied. Useful commands:"
    echo "  Status:  kubectl get rediscluster -n $NAMESPACE"  # cspell:ignore rediscluster
    echo "  Connect: kubectl exec -it redis-cluster-leader-0 -n $NAMESPACE -- redis-cli -c -p 6379 cluster info"
    ;;
  standalone|*)
    echo "==> Applying Redis standalone..."
    kubectl apply -f "$SCRIPT_DIR/redis.yml" -n "$NAMESPACE"
    echo ""
    echo "Redis standalone applied. Useful commands:"
    echo "  Status:  kubectl get redis -n $NAMESPACE"
    echo "  Connect: kubectl exec -it redis-0 -n $NAMESPACE -- redis-cli ping"
    ;;
esac
