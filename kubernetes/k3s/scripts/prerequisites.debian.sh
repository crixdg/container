#!/bin/bash

# Checks all items in checklist section 1.1 Prerequisites — Debian/Ubuntu nodes.
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
if [ -f /etc/debian_version ]; then
  distro=$(. /etc/os-release && echo "$PRETTY_NAME")
  ok "Debian-based distro: $distro"
else
  fail "This script is for Debian/Ubuntu nodes. Detected: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown")"
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
# 4. Required firewall ports — ufw
# ---------------------------------------------------------------------------
header "Firewall ports (ufw)"

PORTS=(
  "6443/tcp:Kubernetes API server"
  "10250/tcp:kubelet metrics"
  "8472/udp:Flannel VXLAN"
  "51820/udp:WireGuard (if enabled)"
  "51821/udp:WireGuard (if enabled)"
  "2379/tcp:etcd client (HA only)"
  "2380/tcp:etcd peer (HA only)"
)

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
  for entry in "${PORTS[@]}"; do
    port_proto="${entry%%:*}"
    purpose="${entry##*:}"
    port="${port_proto%%/*}"
    proto="${port_proto##*/}"

    if ufw status 2>/dev/null | grep -qE "^${port}[/ ]"; then
      ok "Port ${port_proto} — ${purpose}"
    else
      fail "Port ${port_proto} — ${purpose}: no ufw rule found (run: ufw allow ${port_proto})"
    fi
  done
elif command -v iptables &>/dev/null; then
  ipt_output=$(iptables -L INPUT 2>/dev/null || true)
  if [ -z "$ipt_output" ]; then
    info "ufw not active — iptables not readable (run as root to verify rules)"
    for entry in "${PORTS[@]}"; do
      port_proto="${entry%%:*}"; purpose="${entry##*:}"
      info "Port ${port_proto} — ${purpose}: rerun as root to verify"
    done
  else
    input_policy=$(echo "$ipt_output" | awk '/^Chain INPUT/{print $4}' | tr -d '()')
    if [ "$input_policy" = "ACCEPT" ]; then
      info "ufw not active — iptables INPUT policy is ACCEPT (no firewall blocking)"
      for entry in "${PORTS[@]}"; do
        port_proto="${entry%%:*}"; purpose="${entry##*:}"
        ok "Port ${port_proto} — ${purpose}"
      done
    else
      info "ufw not active — iptables INPUT policy is ${input_policy:-unknown}, checking rules"
      for entry in "${PORTS[@]}"; do
        port_proto="${entry%%:*}"
        purpose="${entry##*:}"
        port="${port_proto%%/*}"

        if echo "$ipt_output" | grep -qE "dpt:${port}\b"; then
          ok "Port ${port_proto} — ${purpose} (iptables ACCEPT rule found)"
        else
          fail "Port ${port_proto} — ${purpose}: no ACCEPT rule found (run: ufw allow ${port_proto})"
        fi
      done
    fi
  fi
else
  info "No firewall manager found (ufw/iptables) — ports are likely accessible"
  for entry in "${PORTS[@]}"; do
    port_proto="${entry%%:*}"; purpose="${entry##*:}"
    ok "Port ${port_proto} — ${purpose} (assumed open — no firewall detected)"
  done
fi

# ---------------------------------------------------------------------------
# 5. Required tools
# ---------------------------------------------------------------------------
header "Required tools"
if command -v curl &>/dev/null; then
  ok "curl found: $(curl --version | head -1)"
else
  fail "curl not found — install with: apt-get install -y curl"
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
