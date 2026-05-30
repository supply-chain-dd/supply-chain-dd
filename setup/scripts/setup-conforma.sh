#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CONFORMA_VERSION="${CONFORMA_VERSION:-v0.9.25}"

# ============================================================
# Install ec CLI
# ============================================================

install_ec_cli() {
    if command -v ec >/dev/null 2>&1; then
        INSTALLED_VERSION=$(ec version 2>/dev/null | head -1 || echo "unknown")
        echo "  ✓ ec CLI already installed (${INSTALLED_VERSION})"
        return 0
    fi

    echo "  Detecting OS and architecture..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64)        ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        arm*)          ARCH="arm" ;;
        *)             echo "  ❌ Unsupported architecture: ${ARCH}"; exit 1 ;;
    esac

    ASSET="ec_${OS}_${ARCH}"
    DOWNLOAD_URL="https://github.com/conforma/cli/releases/download/${CONFORMA_VERSION}/${ASSET}"

    echo "  OS: ${OS}, Arch: ${ARCH}"
    echo "  Downloading ${ASSET} from GitHub..."
    curl -sSfL "${DOWNLOAD_URL}" -o /tmp/ec_download
    chmod +x /tmp/ec_download
    mkdir -p ~/.local/bin
    mv /tmp/ec_download ~/.local/bin/ec

    if ! echo "${PATH}" | grep -q "${HOME}/.local/bin"; then
        echo "  ⚠  Add ~/.local/bin to your PATH:"
        echo "     export PATH=\$PATH:~/.local/bin"
    fi

    echo "  ✓ ec CLI ${CONFORMA_VERSION} installed at ~/.local/bin/ec"
}

# ============================================================
# Main
# ============================================================

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Setting up Conforma (Enterprise Contract) ${CONFORMA_VERSION}..."
echo ""
echo "Step 1: Installing ec CLI..."
install_ec_cli

echo ""
echo "Step 2: Checking cosign public key..."
PUBKEY_FILE="${REPO_ROOT}/cosign.pub"
if [ -f "${PUBKEY_FILE}" ]; then
    echo "  ✓ cosign.pub found at ${PUBKEY_FILE}"
else
    echo "  ⚠  cosign.pub not found at ${PUBKEY_FILE}"
    echo "  Run 'make setup-tektonchains' first to generate signing keys, then re-run this target."
fi

echo ""
echo "✓ Conforma setup complete"
echo ""
echo "Usage — validate a signed image from the host:"
echo "  SSL_CERT_FILE=${REPO_ROOT}/setup/certs/registry.crt \\"
echo "  ec validate image \\"
echo "    --images '{\"components\":[{\"name\":\"recipe-api\",\"containerImage\":\"${REGISTRY_HOST}/recipe-api:v1.0\",\"source\":{\"git\":{\"url\":\"http://gitea-http.gitea.svc.cluster.local:3000/sc-admin/recipe-api.git\",\"revision\":\"ed9f32e8da7979f3aa4e3ce8dfedb0a48d5afd9e\"}}}]}' \\"
echo "    --public-key ${PUBKEY_FILE} \\"
echo "    --policy '{\"sources\":[{\"name\":\"sc-minimal\",\"policy\":[\"github.com/conforma/policy//policy/lib\",\"github.com/conforma/policy//policy/release\"],\"config\":{\"include\":[\"@minimal\"],\"exclude\":[\"base_image_registries.base_image_info_found\",\"cve.cve_results_found\"]}}]}' \\"
echo "    --ignore-rekor \\"
echo "    --extra-rule-data allowed_registry_prefixes=registry.registry.svc.cluster.local:5000 \\"
echo "    --extra-rule-data allowed_registry_prefixes=${REGISTRY_HOST} \\"
echo "    --extra-rule-data allowed_registry_prefixes=docker.io \\"
echo "    --extra-rule-data allowed_registry_prefixes=gcr.io \\"
echo "    --extra-rule-data allowed_registry_prefixes=golang \\"
echo "    --output text"
echo ""
echo "Usage — validate via the Tekton pipeline:"
echo "  make trigger-challenge2-build-with-chains"
echo ""
echo "Documentation:"
echo "  - Conforma: https://conforma.dev/docs/"
echo "  - ec validate image: https://conforma.dev/docs/cli/ec_validate_image.html"
