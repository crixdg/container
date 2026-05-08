#!/bin/bash

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
VALUE_FILE="$SCRIPT_DIR/values.yml"

if [ ! -f "$VALUE_FILE" ]; then
  echo "Not found: $VALUE_FILE"
  exit 1
fi

if helm status cloudnative-pg -n cnpg-system > /dev/null 2>&1; then
  echo "Upgrading cloudnative-pg operator..."
  helm upgrade cloudnative-pg cnpg/cloudnative-pg --version 0.23.0 \
    -f "$VALUE_FILE" \
    -n cnpg-system
else
  echo "Installing cloudnative-pg operator..."
  helm install cloudnative-pg cnpg/cloudnative-pg --version 0.23.0 \
    -f "$VALUE_FILE" \
    -n cnpg-system --create-namespace
fi
