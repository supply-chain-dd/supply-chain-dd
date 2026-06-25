#!/usr/bin/env bash

###############################################################################
# demo_challenge_2.sh
#
# Audit de sécurité - Secrets dans les images Docker (Supply Chain Attack)
# Utilise demo-magic pour un affichage interactif "type-along"
#
# Outils utilisés:
#   - skopeo: Listage et inspection des images
#   - gitleaks: Détection de secrets avec regex custom
#   - leaktk: Détection de secrets (alternative à gitleaks)
#   - trufflehog: Détection de secrets (scan profond)
#   - git: Recherche native dans les historiques
#
# Usage: ./demo_challenge_2.sh
###############################################################################

set -uo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
REGISTRY_HOST="registry.sc.local:30443"
REGISTRY_URL="https://${REGISTRY_HOST}"
REGISTRY_USER="admin"
REGISTRY_PASS="RegisterPass123!"

for dir in /tmp/*/audit-git-secrets-demo; do
    [[ -d "${dir}" ]] && rm -rf "${dir}"
done

WORK_DIR="$(mktemp -d)/audit-git-secrets-demo"
REPORTS_DIR="${WORK_DIR}/reports"
CONFIG_DIR="${WORK_DIR}/configs"
EVIDENCE_DIR="${WORK_DIR}/evidence"
LAYERS_DIR="${WORK_DIR}/layers"
ROOTFS_DIR="${WORK_DIR}/rootfs"
GIT_REPOS_DIR="${WORK_DIR}/git-repos"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$(cd "${SCRIPT_DIR}/../../setup/certs" && pwd)"
SSL_CERT_FILE="${CERT_DIR}/registry.crt"
export SSL_CERT_FILE

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

TYPE_SPEED=40
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"
DEMO_CMD_COLOR=$WHITE

pe_() {
    pe "$@"
}

mkdir -p "${REPORTS_DIR}" "${CONFIG_DIR}" "${EVIDENCE_DIR}" "${LAYERS_DIR}" "${ROOTFS_DIR}" "${GIT_REPOS_DIR}" 2>/dev/null

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

#=============================================================================
# INSTALLATION DE GITLEAKS
#=============================================================================
GITLEAKS_VERSION="8.30.1"
GITLEAKS_INSTALL_DIR="/usr/local/bin"

install_gitleaks() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  🔍 Gitleaks n'est pas installé. Installation en cours...          ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "❌ Architecture non supportée: ${arch}"; exit 1 ;;
    esac

    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "${os}" in
        darwin) os="darwin" ;;
        linux) os="linux" ;;
        *) echo "❌ OS non supporté: ${os}"; exit 1 ;;
    esac

    local url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "📥 Téléchargement de Gitleaks ${GITLEAKS_VERSION}..."
    echo "   URL: ${url}"

    if curl -fsSL -o "${tmp_dir}/gitleaks.tar.gz" "${url}"; then
        echo "✅ Téléchargement réussi"
    else
        echo "❌ Échec du téléchargement"
        rm -rf "${tmp_dir}"
        return 1
    fi

    echo "📦 Extraction..."
    tar -xzf "${tmp_dir}/gitleaks.tar.gz" -C "${tmp_dir}" || {
        echo "❌ Échec de l'extraction"
        rm -rf "${tmp_dir}"
        return 1
    }

    local binary="${tmp_dir}/gitleaks"
    if [[ ! -f "${binary}" ]]; then
        binary=$(find "${tmp_dir}" -name "gitleaks" -type f 2>/dev/null | head -1)
    fi

    if [[ ! -f "${binary}" ]]; then
        echo "❌ Binaire non trouvé après extraction"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if [[ -w "${GITLEAKS_INSTALL_DIR}" ]]; then
        cp "${binary}" "${GITLEAKS_INSTALL_DIR}/gitleaks"
        chmod +x "${GITLEAKS_INSTALL_DIR}/gitleaks"
        echo "✅ Gitleaks installé dans ${GITLEAKS_INSTALL_DIR}"
    else
        echo ""
        echo "⚠️  Le répertoire ${GITLEAKS_INSTALL_DIR} n'est pas accessible en écriture."
        echo "   Veuillez entrer votre mot de passe pour installer avec sudo..."
        echo ""
        if sudo cp "${binary}" "${GITLEAKS_INSTALL_DIR}/gitleaks" && sudo chmod +x "${GITLEAKS_INSTALL_DIR}/gitleaks"; then
            echo "✅ Gitleaks installé avec sudo dans ${GITLEAKS_INSTALL_DIR}"
        else
            echo "❌ Échec de l'installation avec sudo"
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    rm -rf "${tmp_dir}"
    echo ""
    echo "🎉 Gitleaks ${GITLEAKS_VERSION} installé avec succès!"
    sleep 2
}

if ! command -v gitleaks >/dev/null 2>&1; then
    install_gitleaks
fi

#=============================================================================
# INSTALLATION DE LEAKSTK
#=============================================================================
LEAKTK_VERSION="0.3.3"
LEAKTK_INSTALL_DIR="/usr/local/bin"

install_leaktk() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  🔧 Leaktk n'est pas installé. Installation en cours...           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
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

    local url="https://github.com/leaktk/leaktk/releases/download/v${LEAKTK_VERSION}/leaktk-${LEAKTK_VERSION}-${os}-${arch}.tar.xz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "📥 Téléchargement de Leaktk ${LEAKTK_VERSION}..."
    echo "   URL: ${url}"

    if curl -fsSL -o "${tmp_dir}/leaktk.tar.xz" "${url}"; then
        echo "✅ Téléchargement réussi"
    else
        echo "❌ Échec du téléchargement"
        rm -rf "${tmp_dir}"
        return 1
    fi

    echo "📦 Extraction..."
    tar -xJf "${tmp_dir}/leaktk.tar.xz" -C "${tmp_dir}" || {
        echo "❌ Échec de l'extraction"
        rm -rf "${tmp_dir}"
        return 1
    }

    local binary="${tmp_dir}/leaktk"
    if [[ ! -f "${binary}" ]]; then
        echo "❌ Binaire non trouvé après extraction"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if [[ -w "${LEAKTK_INSTALL_DIR}" ]]; then
        cp "${binary}" "${LEAKTK_INSTALL_DIR}/leaktk"
        chmod +x "${LEAKTK_INSTALL_DIR}/leaktk"
        echo "✅ Leaktk installé dans ${LEAKTK_INSTALL_DIR}"
    else
        echo ""
        echo "⚠️  Le répertoire ${LEAKTK_INSTALL_DIR} n'est pas accessible en écriture."
        echo "   Veuillez entrer votre mot de passe pour installer avec sudo..."
        echo ""
        if sudo cp "${binary}" "${LEAKTK_INSTALL_DIR}/leaktk" && sudo chmod +x "${LEAKTK_INSTALL_DIR}/leaktk"; then
            echo "✅ Leaktk installé avec sudo dans ${LEAKTK_INSTALL_DIR}"
        else
            echo "❌ Échec de l'installation avec sudo"
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    rm -rf "${tmp_dir}"
    echo ""
    echo "🎉 Leaktk ${LEAKTK_VERSION} installé avec succès!"
    sleep 2
}

if ! command -v leaktk >/dev/null 2>&1; then
    install_leaktk
fi

#=============================================================================
# INSTALLATION DE TRUFFLEHOG
#=============================================================================
TRUFFLEHOG_VERSION="3.95.6"
TRUFFLEHOG_INSTALL_DIR="/usr/local/bin"

install_trufflehog() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  🦆 TruffleHog n'est pas installé. Installation en cours...       ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "❌ Architecture non supportée: ${arch}"; exit 1 ;;
    esac

    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "${os}" in
        darwin) os="darwin" ;;
        linux) os="linux" ;;
        *) echo "❌ OS non supporté: ${os}"; exit 1 ;;
    esac

    local url="https://github.com/trufflesecurity/trufflehog/releases/download/v${TRUFFLEHOG_VERSION}/trufflehog_${TRUFFLEHOG_VERSION}_${os}_${arch}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "📥 Téléchargement de TruffleHog ${TRUFFLEHOG_VERSION}..."
    echo "   URL: ${url}"

    if curl -fsSL -o "${tmp_dir}/trufflehog.tar.gz" "${url}"; then
        echo "✅ Téléchargement réussi"
    else
        echo "❌ Échec du téléchargement"
        rm -rf "${tmp_dir}"
        return 1
    fi

    echo "📦 Extraction..."
    tar -xzf "${tmp_dir}/trufflehog.tar.gz" -C "${tmp_dir}" || {
        echo "❌ Échec de l'extraction"
        rm -rf "${tmp_dir}"
        return 1
    }

    local binary="${tmp_dir}/trufflehog"
    if [[ ! -f "${binary}" ]]; then
        binary=$(find "${tmp_dir}" -name "trufflehog" -type f 2>/dev/null | head -1)
    fi

    if [[ ! -f "${binary}" ]]; then
        echo "❌ Binaire non trouvé après extraction"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if [[ -w "${TRUFFLEHOG_INSTALL_DIR}" ]]; then
        cp "${binary}" "${TRUFFLEHOG_INSTALL_DIR}/trufflehog"
        chmod +x "${TRUFFLEHOG_INSTALL_DIR}/trufflehog"
        echo "✅ TruffleHog installé dans ${TRUFFLEHOG_INSTALL_DIR}"
    else
        echo ""
        echo "⚠️  Le répertoire ${TRUFFLEHOG_INSTALL_DIR} n'est pas accessible en écriture."
        echo "   Veuillez entrer votre mot de passe pour installer avec sudo..."
        echo ""
        if sudo cp "${binary}" "${TRUFFLEHOG_INSTALL_DIR}/trufflehog" && sudo chmod +x "${TRUFFLEHOG_INSTALL_DIR}/trufflehog"; then
            echo "✅ TruffleHog installé avec sudo dans ${TRUFFLEHOG_INSTALL_DIR}"
        else
            echo "❌ Échec de l'installation avec sudo"
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    rm -rf "${tmp_dir}"
    echo ""
    echo "🎉 TruffleHog ${TRUFFLEHOG_VERSION} installé avec succès!"
    sleep 2
}

if ! command -v trufflehog >/dev/null 2>&1; then
    install_trufflehog
fi

#=============================================================================
# VÉRIFICATION DES DÉPENDANCES
#=============================================================================
check_dependencies() {
    local missing_deps=()
    local required_tools=("curl" "jq" "git" "skopeo" "gitleaks")

    for cmd in "${required_tools[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if ! command -v leaktk &> /dev/null; then
        missing_deps+=("leaktk")
    fi

    if ! command -v trufflehog &> /dev/null; then
        missing_deps+=("trufflehog")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "❌ Erreur: Les dépendances suivantes sont manquantes:"
        printf '   - %s\n' "${missing_deps[@]}"
        echo ""
        echo "Installez-les avec:"
        echo "   sudo apt-get install ${missing_deps[*]}   # Debian/Ubuntu"
        exit 1
    fi

    echo "✅ Toutes les dépendances sont présentes"
    echo ""
    echo "   Outils disponibles:"
    for cmd in "${required_tools[@]}" "leaktk" "trufflehog"; do
        printf "      ✓ %s\n" "$cmd"
    done
    echo ""
    sleep 1
}

check_dependencies

#=============================================================================
# FONCTIONS UTILITAIRES
#=============================================================================

list_repositories() {
    curl -fsSL -k -u "${REGISTRY_USER}:${REGISTRY_PASS}" \
        "${REGISTRY_URL}/v2/_catalog" 2>/dev/null \
        | jq -r '.repositories[]?' 2>/dev/null
}

list_tags() {
    local repo="$1"
    skopeo list-tags --tls-verify=false \
        --creds "${REGISTRY_USER}:${REGISTRY_PASS}" \
        "docker://${REGISTRY_HOST}/${repo}" 2>/dev/null \
        | jq -r '.Tags[]?' 2>/dev/null
}

get_layer_digests() {
    local repo="$1" tag="$2"
    skopeo inspect --tls-verify=false \
        --creds "${REGISTRY_USER}:${REGISTRY_PASS}" \
        "docker://${REGISTRY_HOST}/${repo}:${tag}" 2>/dev/null \
        | jq -r '
            if (.Layers // []) | length > 0 then .Layers[]
            elif (.LayersData // []) | length > 0 then .LayersData[].Digest
            else empty end
        ' 2>/dev/null
}

download_blob() {
    local repo="$1" digest="$2" output_file="$3"
    local auth
    auth=$(printf '%s:%s' "${REGISTRY_USER}" "${REGISTRY_PASS}" | base64 | tr -d '\n')
    local attempt=1
    while [[ ${attempt} -le 3 ]]; do
        local http
        http=$(curl -sSL -k -H "Authorization: Basic ${auth}" \
            -o "${output_file}" -w "%{http_code}" --max-time 120 \
            "${REGISTRY_URL}/v2/${repo}/blobs/${digest}" 2>/dev/null) || true
        [[ "${http}" == "200" ]] && [[ -s "${output_file}" ]] && return 0
        rm -f "${output_file}"
        attempt=$((attempt + 1)); sleep 1
    done
    return 1
}

extract_blob() {
    local blob="$1" dir="$2"
    local attempt=1
    local max_attempts=3

    while [[ ${attempt} -le ${max_attempts} ]]; do
        local ft
        ft=$(file -b "${blob}" 2>/dev/null || echo "?")

        local extracted=0

        if echo "${ft}" | grep -qi "zstandard"; then
            zstd -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && extracted=1
        elif echo "${ft}" | grep -qi "gzip\|compressed"; then
            gzip -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && extracted=1
        elif echo "${ft}" | grep -qi "bzip2"; then
            bzip2 -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && extracted=1
        elif echo "${ft}" | grep -qi "XZ"; then
            xz -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && extracted=1
        elif echo "${ft}" | grep -qi "tar"; then
            tar -xf "${blob}" -C "${dir}" 2>/dev/null && extracted=1
        fi

        if [[ ${extracted} -eq 0 ]]; then
            tar -xaf "${blob}" -C "${dir}" 2>/dev/null && extracted=1
        fi

        local c
        c=$(find "${dir}" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

        if [[ "${c}" -gt 1 ]]; then
            return 0
        fi

        if [[ ${attempt} -lt ${max_attempts} ]]; then
            rm -rf "${dir}"/* 2>/dev/null || true
            sleep 1
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

scan_git_repo() {
    local git_dir="$1"
    local repo="$2"
    local tag="$3"
    local layer_idx="$4"

    local git_parent
    git_parent=$(dirname "${git_dir}")

    p ""
    p "# ⚠️  .GIT TROUVÉ dans ${repo}:${tag} (layer ${layer_idx})"
    p "# Analyse: ${git_parent}"

    local safe_name="${repo//\//_}_${tag}_l${layer_idx}"
    local gl_out="${EVIDENCE_DIR}/gitleaks_${safe_name}.json"

    p "# 🔍 Scan Gitleaks..."
    pe_ "gitleaks detect --source=\"${git_parent}\" --report-format=json --report-path=\"${gl_out}\" --no-banner 2>/dev/null || true"
    if [[ -f "${gl_out}" && -s "${gl_out}" ]]; then
        local count
        count=$(jq 'length' "${gl_out}" 2>/dev/null || echo "0")
        if [[ "${count}" -gt 0 ]]; then
            p "#   → ${count} secret(s) trouvé(s) par Gitleaks"
            TOKEN=$(jq -r '.[0].Secret' "${gl_out}" 2>/dev/null | head -n 1)
            [[ -n "$TOKEN" ]] && echo "ARGOCD_AUTH_TOKEN=${TOKEN:0:4}...${TOKEN: -4}" || echo "Aucun secret JWT trouvé dans le fichier."
        else
            p "#   ℹ️ Pas de secrets trouvés par Gitleaks"
        fi
    else
        p "#   ℹ️ Pas de secrets trouvés par Gitleaks"
    fi

    wait

    p "# 🔍 Scan Leaktk..."
    local lt_out="${EVIDENCE_DIR}/leaktk_${safe_name}.jsonl"
    pe_ "leaktk scan \"${git_parent}\" 2>/dev/null | jq -r 'if (.results | length > 0) then .results[] | \"\(.context | ltrimstr(\"\\n\") | split(\"=\")[0])=\(.secret[0:4])....\(.secret[-4:])\" else \"Aucun secret trouvé\" end' | uniq | tee \"${lt_out}\" || true"

    if [[ -s "${lt_out}" ]]; then
        local lt_count
        lt_count=$(wc -l < "${lt_out}" 2>/dev/null || echo "0")
        if [[ "${lt_count}" -gt 0 ]]; then
            p "#   → ${lt_count} secret(s) trouvé(s) par Leaktk"
        else
            p "#   ℹ️ Pas de secrets trouvés par Leaktk"
        fi
    else
        p "#   ℹ️ Pas de secrets trouvés par Leaktk"
    fi

    wait

    p "# 🔍 Scan TruffleHog..."
    local th_out="${EVIDENCE_DIR}/trufflehog_${safe_name}.json"
    p "#   Commande: trufflehog filesystem \"${git_parent}\" --json --no-update"

    # Exécuter la commande - affiche le JSON mais masque les secrets dans la sortie, et affiche les stats
    pe_ "trufflehog filesystem \"${git_parent}\" --json --no-update | tee \"${th_out}\" | grep 'finished scanning' || true"
    # Afficher le résumé basé sur le fichier
    if grep -q '"finished scanning"' "${th_out}" 2>/dev/null; then
            p "#   ℹ️ Pas de secrets trouvés par TruffleHog dans le repository git"
    else
            p "#   ℹ️ Pas de secrets trouvés par TruffleHog dans le repository git"
    fi


    wait
    p "# ----------------------------------------------------------------------"
    p "# 🔍 Recherche dans l'historique git..."
    p "#   Termes: ARGOCD_AUTH_TOKEN, REGISTRY_PASSWORD"

    
    local -a search_terms=("ARGOCD_AUTH_TOKEN" "REGISTRY_PASSWORD")
    local output_file="${EVIDENCE_DIR}/git_history_${safe_name}.txt"

    for term in "${search_terms[@]}"; do
        p "#   Commande: git -C \"${git_parent}\" log --all -p -S ${term} --format=\"COMMIT:%H|%s\""
        # Masquer les secrets dans la sortie (remplace les valeurs longues par un placeholder)
        # Les lignes qui contiennent un token/secret sont masquées
        # On filtre avec awk avant bat
        pe_ "git -C \"${git_parent}\" log --all -p -S \"${term}\" --format=\"COMMIT:%H|%s\" 2>/dev/null | grep -iE \"(${term}|COMMIT:)\" | head -30 | awk '{if (/ARGOCD_AUTH_TOKEN=/ || /REGISTRY_PASSWORD=/) sub(/=.*/, \"=xxxx...xxxx\")} 1' | bat"

        local diff_hits
        diff_hits=$(git -C "${git_parent}" log --all -p -S "${term}" \
            --format="COMMIT:%H|%s" -- 2>/dev/null \
            | grep -iE "(${term}|COMMIT:)" \
            | head -30 \
            | sed -E 's/=[A-Za-z0-9_-]{10,}/=xxxx...xxxx/g') || continue
        if [[ -n "${diff_hits}" ]]; then
            {
                echo "=== GIT LOG -S '${term}' ==="
                echo "${diff_hits}"
                echo ""
            } >> "${output_file}"
        fi
    done

  
}

#=============================================================================
# MAIN - DÉMO INTERACTIVE
#=============================================================================

clear

p "# ======================================================================"
p "# 🎯 DÉMO : Audit de Sécurité - Secrets dans les Images Docker"
p "# ======================================================================"
p "#"
p "# Outils utilisés:"
p "#   📦 skopeo      - Liste et inspection des images"
p "#   🔎 gitleaks    - Détection de secrets"
p "#   🔎 leaktk      - Détection de secrets (alternative)"
p "#   🦆 trufflehog  - Détection de secrets (scan profond)"
p "#   📂 git         - Recherche native dans les historiques"
p "#"


mkdir -p "${REPORTS_DIR}" "${CONFIG_DIR}" "${EVIDENCE_DIR}" 2>/dev/null

p "# ----------------------------------------------------------------------"
p "# 🔍 ÉTAPE 1: Découverte des repositories"
p "# ----------------------------------------------------------------------"

pe_ "curl -sk ${REGISTRY_URL}/v2/_catalog | jq ."

wait

declare -a repos_array=()
mapfile -t repos_array < <(list_repositories)

p "# ----------------------------------------------------------------------"
p "# 📦 ÉTAPE 2: Analyse des images"

p "# ----------------------------------------------------------------------"

repos_array=("${repos_array[@]-}")
if [[ ${#repos_array[@]} -eq 0 ]]; then
    p "# ⚠️ Aucun repository trouvé"
fi

# montrer que ici j'ai 3 images alpine, golang, et recipe-api

# Se concentrer uniquement sur 1 seule, recipe-api

# commencer par trufflehog, il trouve 27 faux positifs
# et tu te dis, est ce qu'il n'y en a pas d'autres?
# donc, tu fais dive
# tu vois qu'il y a un .git, et qu'une layer fait rm .env
# donc tu cherches plus loin
# extraction des layers, gitleaks ou leaktk
# enfin, dire hadolint ne trouve rien, trivy ne trouve rien
# trivy custom misconfiguration

for repo in "${repos_array[@]}"; do
    [[ -z "${repo}" ]] && continue
    p ""
    p "# ======================================================================"
    p "# Image: ${repo}"
    p "# ======================================================================"

    p "# Tags disponibles:"
    pe_ "skopeo list-tags --tls-verify=false docker://${REGISTRY_HOST}/${repo} | jq ."

    wait

    declare -a tags_array=()
    mapfile -t tags_array < <(list_tags "${repo}" 2>/dev/null || true)

    if [[ ${#tags_array[@]} -eq 0 ]]; then
        p "# ℹ️ Aucun tag pour ${repo}"
        continue
    fi

    for tag in "${tags_array[@]}"; do
        [[ -z "${tag}" ]] && continue

        p ""
        p "# ------------------------------------------------------------------"
        p "# Analyse: ${repo}:${tag}"
        p "# ------------------------------------------------------------------"

        p "# 🔍 Scan TruffleHog direct de l'image Docker..."
        th_docker_out="${EVIDENCE_DIR}/trufflehog_docker_${repo//\//_}_${tag}.json"

        pe_ "SSL_CERT_FILE=\"${SSL_CERT_FILE}\" trufflehog docker --image ${REGISTRY_HOST}/${repo}:${tag} --json --no-update | tee \"${th_docker_out}\" | grep 'finished scanning' || true"

        if grep -q '"finished scanning"' "${th_docker_out}" 2>/dev/null; then
            p "#   ℹ️ Pas de secrets trouvés par TruffleHog dans l'image"
        else
            p "#   ℹ️ Pas de secrets trouvés par TruffleHog dans l'image"
        fi

        wait

        declare -a digests_array=()
        mapfile -t digests_array < <(get_layer_digests "${repo}" "${tag}" 2>/dev/null || true)

        if [[ ${#digests_array[@]} -eq 0 ]]; then
            p "# ℹ️ Aucun layer pour ${repo}:${tag}"
            continue
        fi

        p "# ${#digests_array[@]} layer(s) à analyser"

        declare -A seen_git
        layer_with_git=""

        layer_idx=0
        for digest in "${digests_array[@]}"; do
            [[ -z "${digest}" ]] && continue
            layer_idx=$((layer_idx + 1))

            blob_file="${WORK_DIR}/layers/blob_${repo//\//_}_${tag}_${layer_idx}"
            mkdir -p "$(dirname "${blob_file}")"

            if ! download_blob "${repo}" "${digest}" "${blob_file}"; then
                continue
            fi

            if ! extract_blob "${blob_file}" "${ROOTFS_DIR}"; then
                rm -f "${blob_file}"
                continue
            fi
            rm -f "${blob_file}"

            declare -a git_candidates=()
            mapfile -t git_candidates < <(find "${ROOTFS_DIR}" -type d -name '.git' 2>/dev/null || true)

            if [[ ${#git_candidates[@]} -gt 0 && -z "${layer_with_git}" ]]; then
                layer_with_git="${layer_idx}"
            fi

            for candidate in "${git_candidates[@]}"; do
                [[ -z "${candidate}" ]] && continue

                if [[ -n "${seen_git[${candidate}]:-}" ]]; then
                    continue
                fi
                seen_git["${candidate}"]=1

                short="${digest:7:12}"
                safe_name="${repo//\//_}_${tag}_l${layer_idx}_${short}"

                analysis_dir="${WORK_DIR}/git-repos/${safe_name}"
                cp -a "${candidate}" "${analysis_dir}" 2>/dev/null || {
                    analysis_dir="${candidate}"
                }

                scan_git_repo "${candidate}" "${repo}" "${tag}" "${layer_idx}"
            done
        done

         unset seen_git
    done
done

wait
