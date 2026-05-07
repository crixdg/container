#!/bin/bash

# Checks all items in checklist section 1.1 Prerequisites — RHEL/Rocky/AlmaLinux nodes.
# Exits 0 if every check passes, 1 if any check fails.

set -euo pipefail

status=0

ok()     { echo "  [PASS] $*"; }
fail()   { echo "  [FAIL] $*"; status=1; }
info()   { echo "  [INFO] $*"; }
header() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# Distro guard
# ---------------------------------------------------------------------------
header "Distro"
if [ -f /etc/redhat-release ]; then
  distro=$(. /etc/os-release && echo "$PRETTY_NAME")
  ok "RHEL-based distro: $distro"
else
  fail "This script is for RHEL/Rocky/AlmaLinux nodes. Detected: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown")"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. systemd
# ---------------------------------------------------------------------------
header "Init system"
if [ -d /run/systemd/system ]; then
  ok "systemd is running"
else
  fail "systemd not detected — k3s requires a systemd-based distro"
fi

# ---------------------------------------------------------------------------
# 2. Root / passwordless sudo
# ---------------------------------------------------------------------------
header "Privilege"
if [ "$(id -u)" -eq 0 ]; then
  ok "Running as root"
elif sudo -n true 2>/dev/null; then
  ok "Passwordless sudo available (user: $(id -un))"
else
  fail "Not root and no passwordless sudo — install scripts require root or passwordless sudo"
fi

# ---------------------------------------------------------------------------
# 3. Minimum specs: 1 vCPU, 512 MB RAM
# ---------------------------------------------------------------------------
header "Hardware specs"

cpu_count=$(nproc)
if [ "$cpu_count" -ge 1 ]; then
  ok "vCPUs: $cpu_count (minimum 1)"
  [ "$cpu_count" -ge 2 ] || info "Recommended: 2 vCPU"
else
  fail "Could not detect CPU count"
fi

ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
ram_mb=$(( ram_kb / 1024 ))
if [ "$ram_mb" -ge 512 ]; then
  ok "RAM: ${ram_mb} MB (minimum 512 MB)"
  [ "$ram_mb" -ge 2048 ] || info "Recommended: 2048 MB"
else
  fail "RAM: ${ram_mb} MB — minimum 512 MB required"
fi

# ---------------------------------------------------------------------------
# 4. Required firewall ports — firewalld
# ---------------------------------------------------------------------------
header "Firewall ports (firewalld)"

PORTS=(
  "6443/tcp:Kubernetes API server"
  "10250/tcp:kubelet metrics"
  "8472/udp:Flannel VXLAN"
  "51820/udp:WireGuard (if enabled)"
  "51821/udp:WireGuard (if enabled)"
  "2379/tcp:etcd client (HA only)"
  "2380/tcp:etcd peer (HA only)"
)

if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "^running"; then
  for entry in "${PORTS[@]}"; do
    port_proto="${entry%%:*}"
    purpose="${entry##*:}"

    if firewall-cmd --list-ports --permanent 2>/dev/null | grep -qE "(^| )${port_proto}( |$)"; then
      ok "Port ${port_proto} — ${purpose}"
    else
      fail "Port ${port_proto} — ${purpose}: no firewalld rule found (run: firewall-cmd --permanent --add-port=${port_proto} && firewall-cmd --reload)"
    fi
  done
elif command -v iptables &>/dev/null; then
  info "firewalld not active — falling back to iptables"
  for entry in "${PORTS[@]}"; do
    port_proto="${entry%%:*}"
    purpose="${entry##*:}"
    port="${port_proto%%/*}"

    if iptables -L INPUT -n 2>/dev/null | grep -qE "dpt:${port}\b"; then
      ok "Port ${port_proto} — ${purpose} (iptables ACCEPT rule found)"
    else
      info "Port ${port_proto} — ${purpose}: cannot verify — check firewall manually"
    fi
  done
else
  info "No firewall manager found (firewalld/iptables) — verify ports manually"
  for entry in "${PORTS[@]}"; do
    port_proto="${entry%%:*}"; purpose="${entry##*:}"
    info "  Port ${port_proto} — ${purpose}"
  done
fi

# ---------------------------------------------------------------------------
# 5. SELinux
# ---------------------------------------------------------------------------
header "SELinux"
if command -v getenforce &>/dev/null; then
  selinux_mode=$(getenforce)
  case "$selinux_mode" in
    Enforcing)
      ok "SELinux: Enforcing (k3s supports SELinux — install the k3s-selinux policy package before installing k3s)"
      if ! rpm -q k3s-selinux &>/dev/null 2>&1; then
        info "k3s-selinux policy not yet installed (run after adding the rancher repo: dnf install -y k3s-selinux)"
      else
        ok "k3s-selinux policy package installed"
      fi
      ;;
    Permissive)
      info "SELinux: Permissive — k3s will work, but consider setting Enforcing + k3s-selinux in production"
      ;;
    Disabled)
      info "SELinux: Disabled"
      ;;
  esac
else
  info "getenforce not found — SELinux status unknown"
fi

# ---------------------------------------------------------------------------
# 6. Required tools
# ---------------------------------------------------------------------------
header "Required tools"
if command -v curl &>/dev/null; then
  ok "curl found: $(curl --version | head -1)"
else
  fail "curl not found — install with: dnf install -y curl"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [ "$status" -eq 0 ]; then
  echo "All prerequisite checks passed."
else
  echo "One or more prerequisite checks failed. Resolve the items above before installing k3s."
fi

exit "$status"
