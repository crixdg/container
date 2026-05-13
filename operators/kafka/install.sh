#!/bin/bash

# Kafka Operator (Strimzi) — operator install + CR apply
#
# Usage:
#   ./install.sh                        # standalone Kafka (single combined node, dev)
#   KAFKA_MODE=production ./install.sh  # production (3 controllers + 3 brokers, KRaft)
#
# Optional env vars:
#   KAFKA_MODE  — "standalone" (default) or "production"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KAFKA_MODE="${KAFKA_MODE:-standalone}"
OPERATOR_NAMESPACE="kafka-operator"
NAMESPACE="kafka"

# 1. Install Strimzi operator via Helm (idempotent)
helm repo add strimzi https://strimzi.io/charts 2>/dev/null || true
helm repo update strimzi

helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  -f "$SCRIPT_DIR/operator.yml" \
  -n "$OPERATOR_NAMESPACE" --create-namespace --wait

echo "Operator ready in namespace: $OPERATOR_NAMESPACE"

# 2. Create the kafka namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Apply the Kafka CR
case "$KAFKA_MODE" in
  production)
    kubectl apply -f "$SCRIPT_DIR/kafka-production.yml"
    echo "Kafka production cluster (3 controllers + 3 brokers) applied."
    echo "Watch status:  kubectl get kafka,kafkanodepool -n $NAMESPACE"
    echo "Broker pods:   kubectl get pods -n $NAMESPACE -l strimzi.io/pool-name=broker"
    echo "Bootstrap svc: kubectl get svc kafka-kafka-bootstrap -n $NAMESPACE"
    echo "External:      NodePorts 32094-32096 on each broker (bootstrap: 32090)"
    ;;
  standalone|*)
    kubectl apply -f "$SCRIPT_DIR/kafka.yml"
    echo "Kafka standalone applied."
    echo "Watch status:  kubectl get kafka,kafkanodepool -n $NAMESPACE"
    echo "Bootstrap svc: kubectl get svc kafka-kafka-bootstrap -n $NAMESPACE"
    echo "Internal:      kafka-kafka-bootstrap.$NAMESPACE:9092"
    echo "External:      NodePort 32090 (bootstrap)"
    ;;
esac
