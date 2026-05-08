#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT="${1:-$SCRIPT_DIR/__values.yml}"
OUTPUT="${2:-$SCRIPT_DIR/values.yml}"

if [ ! -f "$INPUT" ]; then
	echo "Not found: $INPUT"
	exit 1
fi

awk '
  /^[[:space:]]*# @schema/ { skip = !skip; next }
  skip { next }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { blank++; if (blank == 1) print; next }
  { blank = 0; print }
' "$INPUT" > "$OUTPUT"

echo "Written: $OUTPUT"
