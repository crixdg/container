#!/bin/bash

set -euo pipefail

if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
  echo "Running k3s-uninstall.sh ..."
  /usr/local/bin/k3s-uninstall.sh
elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
  echo "Running k3s-agent-uninstall.sh ..."
  /usr/local/bin/k3s-agent-uninstall.sh
else
  echo "k3s uninstall script not found — is k3s installed on this host?"
  exit 1
fi

echo "k3s removed."

echo "Cleaning up CNI artifacts ..."
umount /run/cilium/cgroupv2 2>/dev/null || true
rm -rf /etc/cni/net.d
rm -rf /opt/cni/bin
rm -rf /var/run/cilium
rm -rf /sys/fs/bpf/tc /sys/fs/bpf/xdp /sys/fs/bpf/cilium 2>/dev/null || true
echo "CNI artifacts removed."

echo "Cleaning up Cilium iptables rules ..."
for table in filter nat mangle; do
  for chain in $(iptables -t "$table" -L -n 2>/dev/null | awk '/^Chain CILIUM|^Chain OLD_CILIUM/{print $2}'); do
    iptables -t "$table" -F "$chain" 2>/dev/null || true
    iptables -t "$table" -X "$chain" 2>/dev/null || true
  done
done
echo "Cilium iptables rules removed."
