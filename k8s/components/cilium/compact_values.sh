#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$K8S_DIR/config/.env"
DEFAULTS="$SCRIPT_DIR/__default_values.yml"

INPUT="${1:-$SCRIPT_DIR/__values.yml}"
OUTPUT="${2:-$SCRIPT_DIR/values.yml}"

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

MERGED=$(python3 - "$DEFAULTS" "$INPUT" <<'PYEOF'
import sys, yaml

def deep_merge(base, override):
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override
    result = base.copy()
    for k, v in override.items():
        result[k] = deep_merge(result.get(k), v)
    return result

with open(sys.argv[1]) as f:
    base = yaml.safe_load(f)
with open(sys.argv[2]) as f:
    override = yaml.safe_load(f)

merged = deep_merge(base, override)
print(yaml.dump(merged, default_flow_style=False, allow_unicode=True, sort_keys=False))
PYEOF
)

awk '
  /^[[:space:]]*# @schema/ { skip = !skip; next }
  skip { next }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { blank++; if (blank == 1) print; next }
  { blank = 0; print }
' <(echo "$MERGED") | envsubst > "$OUTPUT"

echo "Written: $OUTPUT"
