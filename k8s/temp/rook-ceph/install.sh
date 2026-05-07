#!/bin/bash

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
VALUE_FILE="$SCRIPT_DIR/values.yaml"

if [ -f "$VALUE_FILE" ]; then
	helm install rook-ceph rook/rook-ceph --version 1.17.4 \
		-f "$SCRIPT_DIR/values.yaml" \
		-n storage-controller --create-namespace
else
	echo "Not found: $VALUE_FILE"
	exit 1
fi
