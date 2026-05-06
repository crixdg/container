#!/usr/bin/env bash
set -euo pipefail

PUBKEY="${1:-$HOME/.ssh/id_ed25519.pub}"
INVENTORY="${2:-inventory/hosts.ini}"

if [[ ! -f "$PUBKEY" ]]; then
  echo "Error: public key file not found: $PUBKEY"
  exit 1
fi

if [[ ! -f "$INVENTORY" ]]; then
  echo "Error: inventory file not found: $INVENTORY"
  exit 1
fi

# Parse hosts.ini — extract ansible_host and ansible_user values
while IFS= read -r line; do
  # Skip section headers and empty lines
  [[ "$line" =~ ^\[.*\]$ || -z "$line" ]] && continue

  host=$(echo "$line" | grep -oP 'ansible_host=\K[^\s]+')
  user=$(echo "$line" | grep -oP 'ansible_user=\K[^\s]+')

  [[ -z "$host" ]] && continue
  user="${user:-root}"

  echo ">>> Copying key to ${user}@${host} ..."
  ssh-copy-id -i "$PUBKEY" "${user}@${host}"
done < "$INVENTORY"

echo "Done."
