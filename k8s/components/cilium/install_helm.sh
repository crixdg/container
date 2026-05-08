#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if helm repo list | grep -q '^cilium'; then
	echo "Cilium Helm repo already added, skipping."
else
	helm repo add cilium https://helm.cilium.io/
	helm repo update
fi

VALUE_FILE="$SCRIPT_DIR/values.yaml"
DEFAULT_VALUE_FILE="$SCRIPT_DIR/__values.yaml"
VERSION="1.17.4"

if [ ! -f "$VALUE_FILE" ]; then
	VALUE_FILE="$DEFAULT_VALUE_FILE"
fi

if [ ! -f "$VALUE_FILE" ]; then
	echo "Not found: $VALUE_FILE"
	exit 1
fi

helm install cilium cilium/cilium --version $VERSION -f "$VALUE_FILE" \
	-n cni-system --create-namespace
