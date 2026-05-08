#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
VALUES_FILE="$SCRIPT_DIR/values.yml"
TEMPLATE_FILE="$SCRIPT_DIR/__values.yml"
VERSION="$(cat "$SCRIPT_DIR/version.conf")"

REQUIRED_VARS=(API_SERVER_IP API_SERVER_PORT POD_NETWORK_CIDR CLUSTER_NAME)
REQUIRED_BINS=(helm kubectl python3 envsubst)

ERRORS=0
WARNINGS=0

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

pass()  { echo -e "  ${GRN}✔${RST}  $*"; }
fail()  { echo -e "  ${RED}✘${RST}  $*"; ERRORS=$((ERRORS + 1)); }
warn()  { echo -e "  ${YEL}!${RST}  $*"; WARNINGS=$((WARNINGS + 1)); }
info()  { echo -e "  ${CYN}·${RST}  $*"; }
section() { echo -e "\n${CYN}▶ $*${RST}"; }

# ---------------------------------------------------------------------------
section "Required binaries"
# ---------------------------------------------------------------------------
for bin in "${REQUIRED_BINS[@]}"; do
    if command -v "$bin" &>/dev/null; then
        pass "$bin  ($(command -v "$bin"))"
    else
        fail "$bin not found in PATH"
    fi
done

# ---------------------------------------------------------------------------
section ".env file"
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
    fail ".env not found: $ENV_FILE"
    fail "Create it from: $SCRIPT_DIR/.env.example"
    echo -e "\n${RED}Cannot continue without .env — aborting.${RST}"
    exit 1
fi
pass ".env found: $ENV_FILE"

set -o allexport
# shellcheck disable=SC1090
source "$ENV_FILE"
set +o allexport

# ---------------------------------------------------------------------------
section "Required environment variables"
# ---------------------------------------------------------------------------
for var in "${REQUIRED_VARS[@]}"; do
    val="${!var:-}"
    if [ -z "$val" ]; then
        fail "$var is not set (add to $ENV_FILE)"
    else
        pass "$var=$val"
    fi
done

# ---------------------------------------------------------------------------
section "API server connectivity"
# ---------------------------------------------------------------------------
if [ -n "${API_SERVER_IP:-}" ] && [ -n "${API_SERVER_PORT:-}" ]; then
    if timeout 5 bash -c ">/dev/tcp/$API_SERVER_IP/$API_SERVER_PORT" 2>/dev/null; then
        pass "TCP reachable: $API_SERVER_IP:$API_SERVER_PORT"
    else
        fail "Cannot reach API server at $API_SERVER_IP:$API_SERVER_PORT (TCP timeout)"
    fi
else
    warn "Skipping connectivity check — API_SERVER_IP or API_SERVER_PORT not set"
fi

# ---------------------------------------------------------------------------
section "Helm"
# ---------------------------------------------------------------------------
if command -v helm &>/dev/null; then
    if helm repo list 2>/dev/null | grep -q '^cilium'; then
        pass "Helm repo 'cilium' is registered"
        # Check chart version is available
        if helm search repo cilium/cilium --version "$VERSION" --output json 2>/dev/null | grep -q "\"version\":\"$VERSION\""; then
            pass "Chart version $VERSION is available in repo"
        else
            warn "Chart version $VERSION not found — run: helm repo update"
        fi
    else
        fail "Helm repo 'cilium' not added — run: $SCRIPT_DIR/install_repo.sh"
    fi
fi

# ---------------------------------------------------------------------------
section "Generated values.yml"
# ---------------------------------------------------------------------------
if [ ! -f "$VALUES_FILE" ]; then
    fail "values.yml not generated — run: $SCRIPT_DIR/sync_default_values.sh"
else
    # Check it was generated after the template was last modified
    if [ "$TEMPLATE_FILE" -nt "$VALUES_FILE" ]; then
        warn "values.yml is older than __values.yml — run: $SCRIPT_DIR/sync_default_values.sh"
    elif [ "$ENV_FILE" -nt "$VALUES_FILE" ]; then
        warn "values.yml is older than .env — run: $SCRIPT_DIR/sync_default_values.sh"
    else
        pass "values.yml is up to date"
    fi

    # Verify hardcoded IPs are gone (envsubst placeholders were expanded)
    if grep -qE '\$\{[A-Z_]+\}' "$VALUES_FILE"; then
        unexpanded=$(grep -oE '\$\{[A-Z_]+\}' "$VALUES_FILE" | sort -u | tr '\n' ' ')
        fail "Unexpanded placeholders in values.yml: $unexpanded"
    else
        pass "No unexpanded placeholders in values.yml"
    fi
fi

# ---------------------------------------------------------------------------
section "kubectl cluster connectivity"
# ---------------------------------------------------------------------------
if command -v kubectl &>/dev/null; then
    if kubectl cluster-info --request-timeout=5s &>/dev/null; then
        pass "kubectl can reach the cluster"

        # Check for existing Cilium installation
        if helm status cilium -n cni-system &>/dev/null 2>&1; then
            warn "Cilium Helm release already exists in cni-system — this will be an upgrade"
        else
            pass "No existing Cilium Helm release (clean install)"
        fi

        # Check if kube-proxy is running (relevant for kubeProxyReplacement)
        kp_count=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l)
        if [ "$kp_count" -gt 0 ]; then
            info "kube-proxy is running ($kp_count pod(s)) — kubeProxyReplacement is currently set to false (compatible)"
        else
            info "kube-proxy not detected — kubeProxyReplacement=true would be safe if desired"
        fi

        # Node readiness
        not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' | wc -l)
        total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        if [ "$not_ready" -gt 0 ]; then
            warn "$not_ready of $total nodes are not Ready"
        else
            pass "All $total node(s) are Ready"
        fi
    else
        warn "kubectl cannot reach the cluster — skipping cluster checks"
    fi
else
    warn "kubectl not available — skipping cluster checks"
fi

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------
echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo -e "  ${RED}$ERRORS error(s)${RST}, $WARNINGS warning(s) — fix errors before installing"
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "  ${GRN}No errors${RST}, ${YEL}$WARNINGS warning(s)${RST} — review warnings before installing"
    exit 0
else
    echo -e "  ${GRN}All checks passed — ready to install Cilium $VERSION${RST}"
    exit 0
fi
