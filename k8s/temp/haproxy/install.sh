#!/bin/bash

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
VALUE_FILE="$SCRIPT_DIR/values.yaml"

if [ -f "$VALUE_FILE" ]; then
	helm install haproxy bitnami/haproxy --version 2.2.24 \
		-f "$SCRIPT_DIR/values.yaml" \
		-n haproxy --create-namespace
else
	echo "Not found: $VALUE_FILE"
	exit 1
fi
