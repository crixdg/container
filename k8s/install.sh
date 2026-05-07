#!/bin/bash

set -e

if [ -f "$1" ]; then
  read -r RELEASE_NAME NAMESPACE VERSION < "$1"
fi

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

VALUE_FILE="$SCRIPT_DIR/$RELEASE_NAME/values.yaml"

if [ ! -f "$VALUE_FILE" ]; then
  echo "Error: values.yaml not found at $VALUE_FILE"
  exit 1
fi

HELM_ARGS=( -f "$VALUE_FILE" -n "$NAMESPACE" )
if [ -n "$VERSION" ]; then
  HELM_ARGS+=( --version "$VERSION" )
fi

if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
  echo "Upgrading Helm release: $RELEASE_NAME in namespace: $NAMESPACE"
  helm upgrade "$RELEASE_NAME" cilium/cilium "${HELM_ARGS[@]}"
else
  echo "Installing Helm release: $RELEASE_NAME in namespace: $NAMESPACE"
  helm install "$RELEASE_NAME" cilium/cilium "${HELM_ARGS[@]}" --create-namespace
fi
