#!/bin/bash

# Checks all items in checklist section 1.1 Prerequisites.
# Supports Debian/Ubuntu and RHEL/Rocky/AlmaLinux.
# Exits 0 if every check passes, 1 if any check fails.

set -euo pipefail

status=0
OS_FAMILY=""

ok()     { echo "  [PASS] $*"; }
fail()   { echo "  [FAIL] $*"; status=1; }
info()   { echo "  [INFO] $*"; }
header() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
  if [ -f /etc/debian_version ]; then
    OS_FAMILY="debian"
  elif [ -f /etc/redhat-release ]; then
    OS_FAMILY="rhel"
  else
    echo "Error: unsupported OS. Supported: Debian/Ubuntu, RHEL/Rocky/AlmaLinux."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Distro
# ---------------------------------------------------------------------------
check_distro() {
  header "Distro"
  detect_os
  distro=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown")
  if [ "$OS_FAMILY" = "debian" ]; then
    ok "Debian-based distro: $distro"
  else
    ok "RHEL-based distro: $distro"
  fi
}

# ---------------------------------------------------------------------------
# 1. systemd
# ---------------------------------------------------------------------------
check_systemd() {
  header "Init system"
  if [ -d /run/systemd/system ]; then
    ok "systemd is running"
  else
    fail "systemd not detected — k3s requires a systemd-based distro"
  fi
}

# ---------------------------------------------------------------------------
# 2. Root / passwordless sudo
# ---------------------------------------------------------------------------
check_privilege() {
  header "Privilege"
  if [ "$(id -u)" -eq 0 ]; then
    ok "Running as root"
  elif sudo -n true 2>/dev/null; then
    ok "Passwordless sudo available (user: $(id -un))"
  else
    fail "Not root and no passwordless sudo — install scripts require root or passwordless sudo"
  fi
}

# ---------------------------------------------------------------------------
# 3. Minimum specs: 1 vCPU, 512 MB RAM
# ---------------------------------------------------------------------------
check_specs() {
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
}

# ---------------------------------------------------------------------------
# 4. Firewall ports — shared port list, OS-specific firewall tool
# ---------------------------------------------------------------------------
PORTS=(
  "6443/tcp:Kubernetes API server"
  "10250/tcp:kubelet metrics"
  "8472/udp:Flannel VXLAN"
  "51820/udp:WireGuard (if enabled)"
  "51821/udp:WireGuard (if enabled)"
  "2379/tcp:etcd client (HA only)"
  "2380/tcp:etcd peer (HA only)"
)

check_ports_ufw() {
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    for entry in "${PORTS[@]}"; do
      port_proto="${entry%%:*}"; purpose="${entry##*:}"; port="${port_proto%%/*}"
      if ufw status 2>/dev/null | grep -qE "^${port}[/ ]"; then
        ok "Port ${port_proto} — ${purpose}"
      else
        fail "Port ${port_proto} — ${purpose}: no ufw rule found (run: ufw allow ${port_proto})"
      fi
    done
  elif command -v iptables &>/dev/null; then
    ipt_output=$(iptables -L INPUT 2>/dev/null || true)
    if [ -z "$ipt_output" ]; then
      info "ufw not active — iptables not readable (rerun as root to verify)"
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
          port_proto="${entry%%:*}"; purpose="${entry##*:}"; port="${port_proto%%/*}"
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
}

check_ports_firewalld() {
  if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "^running"; then
    for entry in "${PORTS[@]}"; do
      port_proto="${entry%%:*}"; purpose="${entry##*:}"
      if firewall-cmd --list-ports --permanent 2>/dev/null | grep -qE "(^| )${port_proto}( |$)"; then
        ok "Port ${port_proto} — ${purpose}"
      else
        fail "Port ${port_proto} — ${purpose}: no firewalld rule found (run: firewall-cmd --permanent --add-port=${port_proto} && firewall-cmd --reload)"
      fi
    done
  elif command -v iptables &>/dev/null; then
    ipt_output=$(iptables -L INPUT 2>/dev/null || true)
    if [ -z "$ipt_output" ]; then
      info "firewalld not active — iptables not readable (rerun as root to verify)"
      for entry in "${PORTS[@]}"; do
        port_proto="${entry%%:*}"; purpose="${entry##*:}"
        info "Port ${port_proto} — ${purpose}: rerun as root to verify"
      done
    else
      input_policy=$(echo "$ipt_output" | awk '/^Chain INPUT/{print $4}' | tr -d '()')
      if [ "$input_policy" = "ACCEPT" ]; then
        info "firewalld not active — iptables INPUT policy is ACCEPT (no firewall blocking)"
        for entry in "${PORTS[@]}"; do
          port_proto="${entry%%:*}"; purpose="${entry##*:}"
          ok "Port ${port_proto} — ${purpose}"
        done
      else
        info "firewalld not active — iptables INPUT policy is ${input_policy:-unknown}, checking rules"
        for entry in "${PORTS[@]}"; do
          port_proto="${entry%%:*}"; purpose="${entry##*:}"; port="${port_proto%%/*}"
          if echo "$ipt_output" | grep -qE "dpt:${port}\b"; then
            ok "Port ${port_proto} — ${purpose} (iptables ACCEPT rule found)"
          else
            fail "Port ${port_proto} — ${purpose}: no ACCEPT rule found (run: firewall-cmd --permanent --add-port=${port_proto} && firewall-cmd --reload)"
          fi
        done
      fi
    fi
  else
    info "No firewall manager found (firewalld/iptables) — ports are likely accessible"
    for entry in "${PORTS[@]}"; do
      port_proto="${entry%%:*}"; purpose="${entry##*:}"
      ok "Port ${port_proto} — ${purpose} (assumed open — no firewall detected)"
    done
  fi
}

check_firewall() {
  if [ "$OS_FAMILY" = "debian" ]; then
    header "Firewall ports (ufw)"
    check_ports_ufw
  else
    header "Firewall ports (firewalld)"
    check_ports_firewalld
  fi
}

# ---------------------------------------------------------------------------
# 5. SELinux (RHEL only)
# ---------------------------------------------------------------------------
check_selinux() {
  [ "$OS_FAMILY" = "rhel" ] || return 0
  header "SELinux"
  if command -v getenforce &>/dev/null; then
    selinux_mode=$(getenforce)
    case "$selinux_mode" in
      Enforcing)
        ok "SELinux: Enforcing (k3s supports SELinux — k3s-selinux policy must be installed)"
        if ! rpm -q k3s-selinux &>/dev/null 2>&1; then
          info "k3s-selinux not yet installed (run: dnf install -y k3s-selinux)"
        else
          ok "k3s-selinux policy package installed"
        fi
        ;;
      Permissive)
        info "SELinux: Permissive — k3s will work, but consider Enforcing + k3s-selinux in production"
        ;;
      Disabled)
        info "SELinux: Disabled"
        ;;
    esac
  else
    info "getenforce not found — SELinux status unknown"
  fi
}

# ---------------------------------------------------------------------------
# 6. Required tools
# ---------------------------------------------------------------------------
check_tools() {
  header "Required tools"
  if command -v curl &>/dev/null; then
    ok "curl found: $(curl --version | head -1)"
  else
    if [ "$OS_FAMILY" = "debian" ]; then
      fail "curl not found — install with: apt-get install -y curl"
    else
      fail "curl not found — install with: dnf install -y curl"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------
check_distro
check_systemd
check_privilege
check_specs
check_firewall
check_selinux
check_tools

echo
if [ "$status" -eq 0 ]; then
  echo "All prerequisite checks passed."
else
  echo "One or more prerequisite checks failed. Resolve the items above before installing k3s."
fi

exit "$status"
