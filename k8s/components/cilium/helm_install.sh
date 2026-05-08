#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VALUE_FILE="$SCRIPT_DIR/values.yaml"
VERSION="1.18.0-pre.3"

if [ -f "$VALUE_FILE" ]; then
	helm install cilium cilium/cilium --version $VERSION -f "$VALUE_FILE" \
		-n cni-plugin --create-namespace
else
	echo "Not found: $VALUE_FILE"
	exit 1
fi
