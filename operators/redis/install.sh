#!/bin/bash

# Redis Operator (ot-container-kit) — operator install + CR apply
#
# Usage:
#   ./install.sh                   # standalone Redis (single-node)
#   REDIS_MODE=replication ./install.sh  # RedisReplication + RedisSentinel (HA)
#   REDIS_MODE=cluster ./install.sh      # RedisCluster (3 masters, 1 follower each)
#
# Optional env vars:
#   REDIS_PASSWORD  -- if set, creates a redis-secret in the redis namespace
#   REDIS_MODE      -- "standalone" (default), "replication", or "cluster"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REDIS_MODE="${REDIS_MODE:-standalone}"
OPERATOR_NAMESPACE="redis-operator"
NAMESPACE="redis"

# 1. Install the operator via Helm (idempotent)
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts --force-update
helm repo update ot-helm

helm upgrade --install redis-operator ot-helm/redis-operator \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NAMESPACE" --create-namespace --wait

echo "Operator ready in namespace: $OPERATOR_NAMESPACE"

# 2. Create the redis namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Optionally create password secret
if [ -n "$REDIS_PASSWORD" ]; then
  kubectl create secret generic redis-secret \
    --from-literal=password="$REDIS_PASSWORD" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret redis-secret created/updated in namespace: $NAMESPACE"
  echo "Remember to uncomment redisSecret in the CR YAML."
fi

# 4. Apply the Redis CR
case "$REDIS_MODE" in
  replication)
    kubectl apply -f "$SCRIPT_DIR/redis-replication.yml" -n "$NAMESPACE"
    kubectl apply -f "$SCRIPT_DIR/redis-sentinel.yml" -n "$NAMESPACE"
    echo "RedisReplication + RedisSentinel applied."
    echo "Watch status: kubectl get redisreplication,redissentinel -n $NAMESPACE"
    echo "Master discovery (once running): redis-cli -p 26379 -h <sentinel-svc> sentinel get-master-addr-by-name mymaster"
    ;;
  cluster)
    kubectl apply -f "$SCRIPT_DIR/redis-cluster.yml" -n "$NAMESPACE"
    echo "RedisCluster applied (3 masters, 1 follower each — 6 pods total)."
    echo "Watch status: kubectl get rediscluster -n $NAMESPACE"  # cspell:ignore rediscluster
    echo "Connect: kubectl exec -it redis-cluster-leader-0 -n $NAMESPACE -- redis-cli -c -p 6379 cluster info"
    ;;
  standalone|*)
    kubectl apply -f "$SCRIPT_DIR/redis.yml" -n "$NAMESPACE"
    echo "Redis standalone applied."
    echo "Watch status: kubectl get redis -n $NAMESPACE"
    echo "Connect: kubectl exec -it redis-0 -n $NAMESPACE -- redis-cli ping"
    ;;
esac
