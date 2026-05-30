#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

LOOPBACK="127.0.0.1"

ALL_DOMAINS=(
    "${REGISTRY_DOMAIN}"
    "${GITEA_DOMAIN}"
    "${DASHBOARD_DOMAIN}"
    "${REKOR_DOMAIN}"
    "${FULCIO_DOMAIN}"
    "${TUF_DOMAIN}"
    "${ARGOCD_DOMAIN}"
    "${GITEA_PROD_DOMAIN}"
    "${REGISTRY_PROD_DOMAIN}"
    "${APP_DOMAIN}"
)

echo "Configuring /etc/hosts for *.sc.local domains..."
echo ""

for domain in "${ALL_DOMAINS[@]}"; do
    if grep -q "^${LOOPBACK}[[:space:]].*${domain}" /etc/hosts 2>/dev/null; then
        echo "  ✓ ${domain} (already present)"
        continue
    fi

    if grep -q "${domain}" /etc/hosts 2>/dev/null; then
        echo "  ⚠ ${domain} exists with different IP — updating"
        sudo sed -i "/${domain}/d" /etc/hosts
    fi

    echo "${LOOPBACK}  ${domain}" | sudo tee -a /etc/hosts > /dev/null
    echo "  + ${domain} → ${LOOPBACK}"
done

echo ""
echo "✓ /etc/hosts configured for *.sc.local domains"
