#!/usr/bin/env bash

set -euo pipefail

GITEA_URL="http://gitea.sc.local:30080"
GITEA_USER="sc-admin"
GITEA_PASS="SecurePass123!"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEMP_DIR=$(mktemp -d)
REPO_DIR="${TEMP_DIR}/recipe-api"

git clone "http://${GITEA_USER}:${GITEA_PASS}@gitea.sc.local:30080/sc-admin/recipe-api" "${REPO_DIR}"

DOCKERFILE_PATH="${REPO_DIR}/Dockerfile"

DEMO_MAGIC_DIR="${HOME}/demo-magic"
DEMO_MAGIC_SCRIPT="${DEMO_MAGIC_DIR}/demo-magic.sh"

install_demo_magic() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  📦 Demo-magic n'est pas installé. Installation en cours...        ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ -d "${DEMO_MAGIC_DIR}" ]]; then
        rm -rf "${DEMO_MAGIC_DIR}"
    fi

    git clone --depth 1 https://github.com/paxtonhare/demo-magic.git "${DEMO_MAGIC_DIR}" 2>/dev/null || {
        mkdir -p "${DEMO_MAGIC_DIR}"
        curl -fsSL "https://raw.githubusercontent.com/paxtonhare/demo-magic/master/demo-magic.sh" \
            -o "${DEMO_MAGIC_SCRIPT}"
    }

    chmod +x "${DEMO_MAGIC_SCRIPT}"
    echo ""
    echo "🚀 Lancement de la démo..."
    echo ""
    sleep 2
}

if [[ ! -f "${DEMO_MAGIC_SCRIPT}" ]]; then
    install_demo_magic
fi

. "${DEMO_MAGIC_SCRIPT}" -n

TYPE_SPEED=30
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"
DEMO_CMD_COLOR=$WHITE

pe_() {
    pe "$@"
}

#=============================================================================
# INSTALLATION DE HADOLINT
#=============================================================================
HADOLINT_VERSION="2.12.0"
HADOLINT_INSTALL_DIR="/usr/local/bin"

install_hadolint() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  📝 Hadolint n'est pas installé. Installation en cours...          ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) echo "❌ Architecture non supportée: ${arch}"; exit 1 ;;
    esac

    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "${os}" in
        darwin) os="darwin" ;;
        linux) os="linux" ;;
        *) echo "❌ OS non supporté: ${os}"; exit 1 ;;
    esac

    local url="https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-${os}-${arch}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "📥 Téléchargement de Hadolint ${HADOLINT_VERSION}..."
    echo "   URL: ${url}"

    if curl -fsSL -o "${tmp_dir}/hadolint" "${url}"; then
        echo "✅ Téléchargement réussi"
    else
        echo "❌ Échec du téléchargement"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if [[ -w "${HADOLINT_INSTALL_DIR}" ]]; then
        cp "${tmp_dir}/hadolint" "${HADOLINT_INSTALL_DIR}/hadolint"
        chmod +x "${HADOLINT_INSTALL_DIR}/hadolint"
        echo "✅ Hadolint installé dans ${HADOLINT_INSTALL_DIR}"
    else
        echo ""
        echo "⚠️  Le répertoire ${HADOLINT_INSTALL_DIR} n'est pas accessible en écriture."
        echo "   Veuillez entrer votre mot de passe pour installer avec sudo..."
        echo ""
        if sudo cp "${tmp_dir}/hadolint" "${HADOLINT_INSTALL_DIR}/hadolint" && sudo chmod +x "${HADOLINT_INSTALL_DIR}/hadolint"; then
            echo "✅ Hadolint installé avec sudo dans ${HADOLINT_INSTALL_DIR}"
        else
            echo "❌ Échec de l'installation avec sudo"
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    rm -rf "${tmp_dir}"
    echo ""
    echo "🎉 Hadolint ${HADOLINT_VERSION} installé avec succès!"
    sleep 2
}

if ! command -v hadolint >/dev/null 2>&1; then
    install_hadolint
fi

clear

p "# ======================================================================"
p "# 🎯 DÉMO : Audit de Sécurité - Dockerfile"
p "# ======================================================================"

wait

p "# 📝 Affichage du Dockerfile avec bat..."
pe_ "bat --style=numbers ${DOCKERFILE_PATH}"

wait

p "# 📝 Analyse du Dockerfile avec hadolint..."
p "#   Commande: hadolint --ignore DL3008 --ignore DL3009 --ignore DL3015 ${DOCKERFILE_PATH}"

HADOLINT_OUTPUT=$(mktemp)
if hadolint --ignore DL3008 --ignore DL3009 --ignore DL3015 "${DOCKERFILE_PATH}" > "${HADOLINT_OUTPUT}" 2>&1; then
    p "#   ✅ Aucun problème détecté par hadolint"
else
    p "#   ⚠️  Avertissements détectés par hadolint:"
    pe_ "cat ${HADOLINT_OUTPUT}"
fi
rm -f "${HADOLINT_OUTPUT}"

wait


p "# 🐳 Inspection des couches avec dive..."
pe_ "dive podman://registry.sc.local:30443/recipe-api:v1.0"

wait

rm -rf ${TEMP_DIR}
