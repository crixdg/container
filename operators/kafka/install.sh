#!/bin/bash
# Strimzi Kafka operator install + Kafka CR apply
#
# Usage:
#   ./install.sh                        # standalone (single node, dev)
#   KAFKA_MODE=production ./install.sh  # production (3 controllers + 3 brokers, HA)
#
# Optional env vars:
#   KAFKA_MODE   — "standalone" (default) or "production"
#   KAFKA_NS     — Kafka CR namespace (default: kafka)
#   OPERATOR_NS  — operator namespace   (default: kafka-operator)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KAFKA_MODE="${KAFKA_MODE:-standalone}"
KAFKA_NS="${KAFKA_NS:-kafka}"
OPERATOR_NS="${OPERATOR_NS:-kafka-operator}"

echo "==> Mode: $KAFKA_MODE | Kafka namespace: $KAFKA_NS | Operator namespace: $OPERATOR_NS"

# 1. Strimzi Helm repo
echo "==> Adding Strimzi Helm repo..."
helm repo add strimzi https://strimzi.io/charts 2>/dev/null || true
helm repo update strimzi

# 2. Create kafka namespace (operator watchNamespaces requires it to exist first)
echo "==> Creating namespace: $KAFKA_NS"
kubectl create namespace "$KAFKA_NS" --dry-run=client -o yaml | kubectl apply -f -

# 3. Install operator
echo "==> Installing strimzi-kafka-operator..."
helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NS" --create-namespace --wait

echo "==> Operator ready in namespace: $OPERATOR_NS"

# 4. Wait for CRDs then flush kubectl discovery cache
echo "==> Waiting for Strimzi CRDs..."
kubectl wait --for=condition=Established \
  crd/kafkas.kafka.strimzi.io \
  crd/kafkanodepools.kafka.strimzi.io \
  --timeout=90s
rm -rf "${HOME}/.kube/cache/discovery/"

# 5. Apply Kafka CR
case "$KAFKA_MODE" in
  production)
    echo "==> Applying production Kafka cluster (3 controllers + 3 brokers)..."
    kubectl apply -f "$SCRIPT_DIR/kafka-production.yml"
    echo ""
    echo "Production Kafka applied. Useful commands:"
    echo "  Status:        kubectl get kafka,kafkanodepool -n $KAFKA_NS"
    echo "  Broker pods:   kubectl get pods -n $KAFKA_NS -l strimzi.io/pool-name=broker"
    echo "  Bootstrap svc: kubectl get svc kafka-kafka-bootstrap -n $KAFKA_NS"
    echo "  Internal:      kafka-kafka-bootstrap.$KAFKA_NS:9092"
    echo "  External:      NodePort 32090 (bootstrap), 32094-32096 (per broker)"
    ;;
  standalone|*)
    echo "==> Applying standalone Kafka cluster (single combined node)..."
    kubectl apply -f "$SCRIPT_DIR/kafka.yml"
    echo ""
    echo "Standalone Kafka applied. Useful commands:"
    echo "  Status:        kubectl get kafka,kafkanodepool -n $KAFKA_NS"
    echo "  Bootstrap svc: kubectl get svc kafka-kafka-bootstrap -n $KAFKA_NS"
    echo "  Internal:      kafka-kafka-bootstrap.$KAFKA_NS:9092"
    echo "  External:      NodePort 32090"
    ;;
esac
