#!/bin/bash

set -e

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
ENV_FILE="$SCRIPT_DIR/config/.env"

if [ -f "$ENV_FILE" ]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
else
  echo "Missing .env file: $ENV_FILE"
  exit 1
fi

echo "Using .env from: $ENV_FILE"

find "$SCRIPT_DIR" -type f -name "__values.yaml" | while read -r template; do
  output="${template%__values.yaml}values.yaml"
  echo "Generating: $output"
  envsubst < "$template" > "$output"
done

echo "All templates rendered successfully."
