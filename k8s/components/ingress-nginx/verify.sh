#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
VALUES_FILE="$SCRIPT_DIR/values.yml"
TEMPLATE_FILE="$SCRIPT_DIR/__values.yml"
VERSION="$(cat "$SCRIPT_DIR/version.conf")"

REQUIRED_VARS=()
REQUIRED_BINS=(helm kubectl python3 envsubst)

ERRORS=0
WARNINGS=0

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

pass()    { echo -e "  ${GRN}✔${RST}  $*"; }
fail()    { echo -e "  ${RED}✘${RST}  $*"; ERRORS=$((ERRORS + 1)); }
warn()    { echo -e "  ${YEL}!${RST}  $*"; WARNINGS=$((WARNINGS + 1)); }
info()    { echo -e "  ${CYN}·${RST}  $*"; }
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
if [ "${#REQUIRED_VARS[@]}" -eq 0 ]; then
    info "No required variables defined"
else
    for var in "${REQUIRED_VARS[@]}"; do
        val="${!var:-}"
        if [ -z "$val" ]; then
            fail "$var is not set (add to $ENV_FILE)"
        else
            pass "$var=$val"
        fi
    done
fi

# ---------------------------------------------------------------------------
section "Helm"
# ---------------------------------------------------------------------------
if command -v helm &>/dev/null; then
    if helm repo list 2>/dev/null | grep -q '^ingress-nginx'; then
        pass "Helm repo 'ingress-nginx' is registered"
        if helm search repo ingress-nginx/ingress-nginx --version "$VERSION" --output json 2>/dev/null | grep -q "\"version\":\"$VERSION\""; then
            pass "Chart version $VERSION is available in repo"
        else
            warn "Chart version $VERSION not found — run: helm repo update"
        fi
    else
        fail "Helm repo 'ingress-nginx' not added — run: $SCRIPT_DIR/install_repo.sh"
    fi
fi

# ---------------------------------------------------------------------------
section "Generated values.yml"
# ---------------------------------------------------------------------------
if [ ! -f "$VALUES_FILE" ]; then
    fail "values.yml not generated — run: $SCRIPT_DIR/generate_values.sh"
else
    if [ "$TEMPLATE_FILE" -nt "$VALUES_FILE" ]; then
        warn "values.yml is older than __values.yml — run: $SCRIPT_DIR/generate_values.sh"
    elif [ "$ENV_FILE" -nt "$VALUES_FILE" ]; then
        warn "values.yml is older than .env — run: $SCRIPT_DIR/generate_values.sh"
    else
        pass "values.yml is up to date"
    fi

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

        if helm status ingress-nginx -n ingress-nginx &>/dev/null 2>&1; then
            warn "ingress-nginx Helm release already exists in ingress-nginx — this will be an upgrade"
        else
            pass "No existing ingress-nginx Helm release (clean install)"
        fi

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
    echo -e "  ${GRN}All checks passed — ready to install ingress-nginx $VERSION${RST}"
    exit 0
fi
