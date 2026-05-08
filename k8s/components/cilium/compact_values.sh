#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$K8S_DIR/config/.env"

SLIM=false
POSITIONAL=()
for arg in "$@"; do
	case "$arg" in
		--slim) SLIM=true ;;
		*) POSITIONAL+=("$arg") ;;
	esac
done

INPUT="${POSITIONAL[0]:-$SCRIPT_DIR/__values.yml}"
OUTPUT="${POSITIONAL[1]:-$SCRIPT_DIR/values.yml}"

if [ ! -f "$INPUT" ]; then
	echo "Not found: $INPUT"
	exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
	echo "Missing .env file: $ENV_FILE"
	exit 1
fi

set -o allexport
# shellcheck disable=SC1090
source "$ENV_FILE"
set +o allexport

awk -v slim="$SLIM" '
  /^[[:space:]]*# @schema/ { skip = !skip; next }
  skip { next }
  /^[[:space:]]*#/ { next }
  slim == "true" && /^[[:space:]]*[^:]+:[[:space:]]*(\[\]|""|'"''"'|\{\}|null|~)[[:space:]]*$/ { next }
  /^[[:space:]]*$/ { blank++; if (blank == 1) print; next }
  { blank = 0; print }
' "$INPUT" | envsubst > "$OUTPUT"

echo "Written: $OUTPUT"
