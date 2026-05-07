#!/bin/bash

set -euo pipefail

K3S_BIN_DIR="${K3S_BIN_DIR:-/usr/local/bin}"

if [ -f "$K3S_BIN_DIR/k3s-uninstall.sh" ]; then
  echo "Running k3s-uninstall.sh ..."
  "$K3S_BIN_DIR/k3s-uninstall.sh"
elif [ -f "$K3S_BIN_DIR/k3s-agent-uninstall.sh" ]; then
  echo "Running k3s-agent-uninstall.sh ..."
  "$K3S_BIN_DIR/k3s-agent-uninstall.sh"
else
  echo "k3s uninstall script not found — is k3s installed on this host?"
  exit 1
fi

echo "k3s removed."
