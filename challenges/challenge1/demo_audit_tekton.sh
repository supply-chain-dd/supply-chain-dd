#!/usr/bin/env bash

###############################################################################
# demo_audit_tekton.sh
#
# Audit de sécurité - Configuration Tekton vulnérable
# Utilise demo-magic pour un affichage interactif "type-along"
# Utilise bat pour afficher les fichiers avec coloration syntaxique
#
# Usage: ./demo_audit_tekton.sh
###############################################################################

set -uo pipefail

#=============================================================================
# CONFIGURATION - Chemin dynamique basé sur pwd
#=============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VICTIM_REPO="${SCRIPT_DIR}/../victim-repo-sample"
TEKTON_DIR="${VICTIM_REPO}/.tekton"

#=============================================================================
# COULEURS
#=============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

#=============================================================================
# INSTALLATION DE BAT
#=============================================================================
BAT_VERSION="0.24.0"
BAT_INSTALL_DIR="/usr/local/bin"

install_bat() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  🦇 Bat n'est pas installé. Installation en cours...              ║"
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

    local url="https://github.com/sharkdp/bat/releases/download/v${BAT_VERSION}/bat-v${BAT_VERSION}-${arch}-unknown-${os}-musl.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "📥 Téléchargement de Bat ${BAT_VERSION}..."
    echo "   URL: ${url}"

    if curl -fsSL -o "${tmp_dir}/bat.tar.gz" "${url}"; then
        echo "✅ Téléchargement réussi"
    else
        echo "❌ Échec du téléchargement"
        rm -rf "${tmp_dir}"
        return 1
    fi

    echo "📦 Extraction..."
    tar -xzf "${tmp_dir}/bat.tar.gz" -C "${tmp_dir}" || {
        echo "❌ Échec de l'extraction"
        rm -rf "${tmp_dir}"
        return 1
    }

    local binary="${tmp_dir}/bat-v${BAT_VERSION}-${arch}-unknown-${os}-musl/bat"
    if [[ ! -f "${binary}" ]]; then
        binary=$(find "${tmp_dir}" -name "bat" -type f 2>/dev/null | head -1)
    fi

    if [[ ! -f "${binary}" ]]; then
        echo "❌ Binaire non trouvé après extraction"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if [[ -w "${BAT_INSTALL_DIR}" ]]; then
        cp "${binary}" "${BAT_INSTALL_DIR}/bat"
        chmod +x "${BAT_INSTALL_DIR}/bat"
        echo "✅ Bat installé dans ${BAT_INSTALL_DIR}"
    else
        echo ""
        echo "⚠️  Le répertoire ${BAT_INSTALL_DIR} n'est pas accessible en écriture."
        echo "   Veuillez entrer votre mot de passe pour installer avec sudo..."
        echo ""
        if sudo cp "${binary}" "${BAT_INSTALL_DIR}/bat" && sudo chmod +x "${BAT_INSTALL_DIR}/bat"; then
            echo "✅ Bat installé avec sudo dans ${BAT_INSTALL_DIR}"
        else
            echo "❌ Échec de l'installation avec sudo"
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    rm -rf "${tmp_dir}"
    echo ""
    echo "🎉 Bat ${BAT_VERSION} installé avec succès!"
    sleep 2
}

if ! command -v bat >/dev/null 2>&1; then
    install_bat
fi

#=============================================================================
# INSTALLATION DE DEMO-MAGIC
#=============================================================================
DEMO_MAGIC_DIR="${HOME}/demo-magic"
DEMO_MAGIC_SCRIPT="${DEMO_MAGIC_DIR}/demo-magic.sh"

install_demo_magic() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  📦 Demo-magic n'est pas installé. Installation en cours...        ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    if ! command -v git &> /dev/null; then
        echo "❌ Erreur: git n'est pas installé. Veuillez l'installer d'abord."
        exit 1
    fi

    if [[ -d "${DEMO_MAGIC_DIR}" ]]; then
        echo "🧹 Nettoyage de l'installation précédente..."
        rm -rf "${DEMO_MAGIC_DIR}"
    fi

    echo "📥 Clonage de demo-magic depuis GitHub..."
    if git clone --depth 1 https://github.com/paxtonhare/demo-magic.git "${DEMO_MAGIC_DIR}" 2>/dev/null; then
        echo "✅ Demo-magic installé avec succès dans ${DEMO_MAGIC_DIR}"
    else
        echo "❌ Erreur lors du clonage de demo-magic"
        echo "   Tentative de téléchargement direct..."

        mkdir -p "${DEMO_MAGIC_DIR}"
        if command -v curl &> /dev/null; then
            curl -fsSL "https://raw.githubusercontent.com/paxtonhare/demo-magic/master/demo-magic.sh" \
                -o "${DEMO_MAGIC_SCRIPT}"
        elif command -v wget &> /dev/null; then
            wget -q "https://raw.githubusercontent.com/paxtonhare/demo-magic/master/demo-magic.sh" \
                -O "${DEMO_MAGIC_SCRIPT}"
        else
            echo "❌ Erreur: ni curl ni wget n'est disponible"
            exit 1
        fi
        echo "✅ Demo-magic téléchargé avec succès"
    fi

    if [[ ! -f "${DEMO_MAGIC_SCRIPT}" ]]; then
        echo "❌ Erreur: Le fichier demo-magic.sh n'a pas été trouvé après installation"
        exit 1
    fi

    chmod +x "${DEMO_MAGIC_SCRIPT}"
    echo ""
    echo "🚀 Lancement de la démo..."
    echo ""
    sleep 2
}

if [[ ! -f "${DEMO_MAGIC_SCRIPT}" ]]; then
    install_demo_magic
fi

# shellcheck source=/dev/null
. "${DEMO_MAGIC_SCRIPT}" -n

TYPE_SPEED=30
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"
DEMO_CMD_COLOR=$WHITE

pe_() {
    pe "$@"
}

#=============================================================================
# MAIN - DÉMO INTERACTIVE
#=============================================================================

clear

p "# ======================================================================"
p "# 🎯 DÉMO : Audit de Sécurité - Configuration Tekton"
p "# ======================================================================"
p "#"
p "# Outils utilisés:"
p "#   🦇 bat     - Affichage syntaxique des fichiers"
p "#   📂 Fichiers analysés:"
p "#      - vulnerable-quality-check-task.yaml"
p "#      - vulnerable-eventlistener.yaml"
p "#"
wait

p "# ----------------------------------------------------------------------"
p "# 🔍 ÉTAPE 1: Clone du fork de l'attaquant"
p "# ----------------------------------------------------------------------"
p "# Fichier: vulnerable-eventlistener.yaml (TriggerBinding)"
p "# Problème: Utilise head.repo (fork de l'attaquant) au lieu de base.repo"
p "#"

wait

p "# 📄 TriggerBinding utilisant le head (fork de l'attaquant):"
pe_ "bat --style=numbers -r 35:48 ${TEKTON_DIR}/triggers/vulnerable-eventlistener.yaml"

wait

p "# ----------------------------------------------------------------------"
p "# 🚨 ÉTAPE 2: Exécution de code arbitraire (RCE)"
p "# ----------------------------------------------------------------------"
p "# Fichier: vulnerable-quality-check-task.yaml"
p "# Problème: Le pipeline exécute 'go run' sur le code du fork cloné"
p "#"

wait

p "# 📄 Task exécutant le code du fork:"
pe_ "bat --style=numbers -r 68:72 ${TEKTON_DIR}/tasks/vulnerable-quality-check-task.yaml"

wait

p "# ----------------------------------------------------------------------"
p "# 🚨 ÉTAPE 3: RBAC trop permissif - ServiceAccount default"
p "# ----------------------------------------------------------------------"
p "# Fichier: vulnerable-eventlistener.yaml"
p "# Problème: Le ServiceAccount 'default' peut lire TOUS les secrets"
p "#"

wait

p "# 📄 Role avec accès aux secrets:"
pe_ "bat --style=numbers -r 165:177 ${TEKTON_DIR}/triggers/vulnerable-eventlistener.yaml"

wait

p "# 📄 RoleBinding avec ServiceAccount default:"
pe_ "bat --style=numbers -r 186:192 ${TEKTON_DIR}/triggers/vulnerable-eventlistener.yaml"

wait

p "# ----------------------------------------------------------------------"
p "# 🔐 ÉTAPE 4: Secrets codés en dur"
p "# ----------------------------------------------------------------------"
p "# Fichier: vulnerable-eventlistener.yaml"
p "# Problème: Le secret webhook est codé en dur"
p "#"

wait

p "# 📄 Secret codé en dur:"
pe_ "bat --style=numbers -r 193:200 ${TEKTON_DIR}/triggers/vulnerable-eventlistener.yaml"

wait

p "# ======================================================================"
p "# 🎯 RÉSUMÉ DE LA CHAÎNE D'ATTAQUE"
p "# ======================================================================"
p "#"
p "# | Étape | Vulnérabilité                                    |"
p "# |-------|---------------------------------------------------|"
p "# |   1   | Clone du fork de l'attaquant (head.repo)      |"
p "# |   2   | Exécution RCE via 'go run' sur code non fiable  |"
p "# |   3   | Accès aux secrets via ServiceAccount default    |"
p "# |   4   | Secret codé en dur (webhook)                    |"
p "#"
wait

p "# ======================================================================"
p "# 🛡️ RECOMMANDATIONS DE SÉCURITÉ"
p "# ======================================================================"
p "#"
p "# 1. TRIGGER BINDING:"
p "#    - Utiliser base.repo au lieu de head.repo"
p "#    - Valider les inputs avant utilisation"
p "#"
p "# 2. EXÉCUTION DE CODE:"
p "#    - Remplacer 'go run' par analyse statique"
p "#    - Ne jamais exécuter de code non fiable!"
p "#"
p "# 3. RBAC:"
p "#    - Restreindre l'accès aux secrets spécifiques"
p "#    - Utiliser un ServiceAccount dédié avec permissions minimales"
p "#    - NE PAS utiliser le ServiceAccount 'default'"
p "#"
p "# 4. SECRETS:"
p "#    - Utiliser des secrets sécurisés générés aléatoirement"
p "#    - Les stocker dans un Vault ou SealedSecret"
p "#"
wait

p "# ======================================================================"
p "# 🎉 FIN DE L'AUDIT TEKTON"
p "# ======================================================================"
wait