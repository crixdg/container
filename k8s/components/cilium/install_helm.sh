#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$SCRIPT_DIR/install_repo.sh"

VALUE_FILE="$SCRIPT_DIR/values.yaml"
MY_DEFAULT_VALUE_FILE="$SCRIPT_DIR/__values.yaml"
DEFAULT_VALUE_FILE="$SCRIPT_DIR/__default_values.yaml"
VERSION="$(cat $SCRIPT_DIR/version.conf)"


if [ ! -f "$VALUE_FILE" ]; then
	VALUE_FILE="$MY_DEFAULT_VALUE_FILE"
	if [ ! -f "$VALUE_FILE" ]; then
		VALUE_FILE="$DEFAULT_VALUE_FILE"
	fi
fi

if [ ! -f "$VALUE_FILE" ]; then
	echo "Not found: $VALUE_FILE"
	exit 1
fi

helm install cilium cilium/cilium --version $VERSION -f "$VALUE_FILE" \
	-n cni-system --create-namespace
