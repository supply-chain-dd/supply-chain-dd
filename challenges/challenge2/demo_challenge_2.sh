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
#   - git: Recherche native dans les historiques
#
# Usage: ./demo_challenge_2.sh
###############################################################################

set -uo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
REGISTRY_URL="https://registry.sc.local:30443"
REGISTRY_USER="admin"
REGISTRY_PASS="RegisterPass123!"
REGISTRY_HOST="registry.sc.local:30443"

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

mkdir -p "${REPORTS_DIR}" "${CONFIG_DIR}" "${EVIDENCE_DIR}" "${LAYERS_DIR}" "${ROOTFS_DIR}" "${GIT_REPOS_DIR}"

p "# ======================================================================"
p "# 📁 Répertoire de travail: ${WORK_DIR}"
p "# ======================================================================"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${REPORTS_DIR}/audit_report_${TIMESTAMP}.md"

SENSITIVE_VARS=(
    'ARGOCD_AUTH_TOKEN'
    'COSIGN_PASSWORD'
    'COSIGN_KEY'
    'DOCKER_PASSWORD'
    'DOCKER_AUTH'
    'INTERNAL_TOKEN'
    'SECRET_KEY'
    'API_KEY'
    'AWS_SECRET_ACCESS_KEY'
    'GITHUB_TOKEN'
    'GITLAB_TOKEN'
    'NPM_TOKEN'
    'DATABASE_PASSWORD'
    'DB_PASSWORD'
    'REDIS_PASSWORD'
    'JWT_SECRET'
    'PRIVATE_KEY'
)

TOKEN_PATTERNS=(
    'AKIA[0-9A-Z]{16}'
    'ghp_[A-Za-z0-9]{20,}'
    'glpat-[A-Za-z0-9_-]{20,}'
    'ghr_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
    'xox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}'
    'sk-[A-Za-z0-9]{48}'
    'rk-[A-Za-z0-9]{48}'
    'Bearer [A-Za-z0-9_-]{20,}'
    'BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY'
)

build_secret_regex() {
    local all_patterns=()
    all_patterns+=("${TOKEN_PATTERNS[@]}")
    for var in "${SENSITIVE_VARS[@]}"; do
        all_patterns+=("${var}[[:space:]]*[=:][[:space:]]*[^[:space:]]+")
        all_patterns+=("${var}")
    done
    SECRET_REGEX="($(IFS='|'; echo "${all_patterns[*]}"))"
}

build_secret_regex

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
    pe "$@" 2>/dev/null
}

#=============================================================================
# INSTALLATION DE LEAKSTK
#=============================================================================
LEAKTK_VERSION="0.3.3"
LEAKTK_INSTALL_DIR="/usr/local/bin"

install_leaktk() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  🔧 Leaktk n'est pas installé. Installation en cours...           ║"
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

    local url="https://github.com/leakstk/leaktk/releases/download/v${LEAKTK_VERSION}/leaktk-${LEAKTK_VERSION}-${os}-${arch}.tar.xz"
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
    for cmd in "${required_tools[@]}" "leaktk"; do
        printf "      ✓ %s\n" "$cmd"
    done
    echo ""
    sleep 1
}

check_dependencies

#=============================================================================
# FONCTIONS UTILITAIRES
#=============================================================================

generate_gitleaks_config() {
    mkdir -p "${CONFIG_DIR}"
    
    local rules_json="["
    local first_rule=true
    
    for pattern in "${TOKEN_PATTERNS[@]}"; do
        if [[ "$first_rule" == "true" ]]; then
            first_rule=false
        else
            rules_json+=","
        fi
        rules_json+="{\"id\":\"CUSTOM-$(echo "$pattern" | head -c 8 | tr '[:lower:]' '[:upper:]' | tr -cd '[:alnum:]')\",\"description\":\"Custom pattern\",\"regex\":\"$pattern\",\"entropy\":0}"
    done
    
    for var in "${SENSITIVE_VARS[@]}"; do
        rules_json+=",{\"id\":\"CUSTOM-${var}\",\"description\":\"Sensitive variable ${var}\",\"regex\":\"${var}[[:space:]]*[=:][[:space:]]*[^[:space:]]+\",\"entropy\":0}"
    done
    rules_json+="]"
    
    cat > "${CONFIG_DIR}/gitleaks.toml" <<EOF
title = "Custom Rules"
[extend]
useDefault = true

[rules]
${rules_json}
EOF
}

mask_value() {
    echo "$1" | sed -E 's/(=["\x27]?)([^"\x27]{8})([^"\x27]{5,})([^"\x27]{4})(["\x27]?)/\1\2...\4\5/g'
}

init_workspace() {
    rm -rf "${WORK_DIR}"
    mkdir -p "${REPORTS_DIR}" "${CONFIG_DIR}" "${EVIDENCE_DIR}"
    generate_gitleaks_config
}

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

git_work_dir() {
    local candidate="$1"
    local base
    base=$(basename "${candidate}")
    
    if [[ "${base}" == ".git" ]]; then
        if [[ -d "${candidate}" ]]; then
            dirname "${candidate}"
        elif [[ -f "${candidate}" ]]; then
            dirname "${candidate}"
        fi
    elif [[ -d "${candidate}" && -f "${candidate}/HEAD" ]]; then
        echo "${candidate}"
    fi
}

search_git_in_image() {
    local repo="$1" tag="$2"
    local config_dir="${WORK_DIR}/config_${repo//\//_}_${tag//\//_}"
    mkdir -p "${config_dir}"
    
    p "# Recherche alternative: config blob de l'image..."
    
    local raw_manifest
    raw_manifest=$(skopeo inspect --tls-verify=false --raw "docker://${REGISTRY_HOST}/${repo}:${tag}" 2>/dev/null || echo "")
    
    if [[ -z "${raw_manifest}" ]]; then
        p "#   ℹ️ Impossible d'obtenir le manifeste raw"
        return 1
    fi
    
    local config_digest
    config_digest=$(echo "${raw_manifest}" | jq -r '.config // .Config // empty' 2>/dev/null || true)
    
    if [[ -z "${config_digest}" ]]; then
        p "#   ℹ️ Pas de config digest trouvé dans le manifeste"
        return 1
    fi
    
    p "#   → Config digest: ${config_digest:0:30}..."
    
    local config_file="${config_dir}/config.json"
    if download_blob "${repo}" "${config_digest}" "${config_file}"; then
        p "#   ✅ Config blob téléchargé"
        
        local history
        history=$(echo "${raw_manifest}" | jq -r '.history[]?' 2>/dev/null || true)
        
        if [[ -n "${history}" ]]; then
            p "#   → ${history}"
        fi
        
        rm -rf "${config_dir}"
    else
        p "#   ⚠️ Échec du téléchargement du config blob"
        rm -rf "${config_dir}"
        return 1
    fi
    
    return 0
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
            p "# Tentative ${attempt}/${max_attempts} échouée, nouvelle tentative..."
            rm -rf "${dir}"/* 2>/dev/null || true
            sleep 1
        fi
        
        attempt=$((attempt + 1))
    done
    
    p "# Diagnostic: premiers bytes du fichier"
    xxd -l 64 "${blob}" 2>/dev/null || true
    
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
    
    p "# 🔍 Scan Gitleaks..."
    p "#   Commande: gitleaks detect --source=\"\${SOURCE_PATH}\" --report-format=json --no-banner"
    local gl_out="${EVIDENCE_DIR}/gitleaks_${safe_name}.json"
    gitleaks detect --source="${git_parent}" \
        --report-format=json \
        --report-path="${gl_out}" \
        --no-banner 2>/dev/null || true
    
    if [[ -f "${gl_out}" && -s "${gl_out}" ]]; then
        local count
        count=$(jq 'length' "${gl_out}" 2>/dev/null || echo "0")
        if [[ "${count}" -gt 0 ]]; then
            p "#   → ${count} secret(s) trouvé(s) par Gitleaks"
            pe_ "cat \"${gl_out}\" | jq -r '\"ARGOCD_AUTH_TOKEN=\" + (.[].Secret | .[0:5] + \"...\" + .[-5:])' 2>/dev/null"
        fi
    fi
    
    wait
    
    p "# 🔍 Scan Leaktk..."
    p "#   Commande: leaktk scan \"\${SOURCE_PATH}\" "
    local lt_out="${EVIDENCE_DIR}/leaktk_${safe_name}.jsonl"
    leaktk scan "${git_parent}" 2>/dev/null > "${lt_out}" || true
    
    if [[ -s "${lt_out}" ]]; then
        local lt_count
        lt_count=$(wc -l < "${lt_out}" 2>/dev/null || echo "0")
        if [[ "${lt_count}" -gt 0 ]]; then
            p "#   → ${lt_count} secret(s) trouvé(s) par Leaktk"
			cat "${lt_out}"  | jq -r '.results[0].match| capture("(?<var>[^=]+)=(?<token>.*)")| "\(.var)=\(.token[0:5])...\(.token[-5:])"'
        fi
    fi
    
    wait
    
    p "# 🔍 Scan brut des objets git (scan_git_raw)..."
    local raw_out="${EVIDENCE_DIR}/rawgit_${safe_name}.txt"
    if scan_git_raw "${git_parent}" "${raw_out}"; then
        p "#   → Secrets trouvés dans les objets git bruts"
    fi
    
    wait
    
    p "# 🔍 Recherche dans l'historique git (git log -S)..."
    p "#   Commandes: git log -S \${CRED} pour chaque credential"
    p "#   Exemple: git log --all -p -S \"ARGOCD_AUTH_TOKEN\""
    
    local -a search_terms=("password" "secret" "token" "api_key" "credential" "bearer" "ARGOCD" "COSIGN")
    
    for term in "${search_terms[@]}"; do
        local diff_hits
        diff_hits=$(git -C "${git_parent}" log --all -p -S "${term}" \
            --format="COMMIT:%H|%s" -- 2>/dev/null \
            | grep -iE "(${term}|COMMIT:)" \
            | head -10) || continue
        
        if [[ -n "${diff_hits}" ]]; then
            p "#   → Présence de '${term}' dans l'historique"
            local log_out="${EVIDENCE_DIR}/rawgit_${safe_name}_${term}.txt"
            {
                echo "=== GIT LOG -S '${term}' ==="
                echo "${diff_hits}"
            } > "${log_out}"
        fi
    done
    
    wait
}

scan_git_raw() {
    local repo_root="$1"
    local output_file="$2"
    
    p "#   [raw-scan] Analyse des objets git bruts..."
    p "#   Commandes: git rev-list --objects --all, git fsck --unreachable, git log --all --full-history --diff-filter=ACDMR"
    
    local regex='(password|passwd|secret|token|api[_-]?key|apikey|access[_-]?key'
    regex+='|credential|bearer|private.?key|PRIVATE KEY'
    regex+='|ghp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,}'
    regex+='|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}'
    regex+='|kubeconfig|serviceAccountToken'
    regex+='|argocd|admin\.password|server\.secretkey'
    regex+='|INTERNAL_TOKEN|SECRET_KEY|LFS_JWT_SECRET'
    regex+='|COSIGN_PASSWORD|COSIGN_KEY'
    regex+='|DOCKER_PASSWORD|DOCKER_AUTH|dockerconfigjson'
    regex+='|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID'
    regex+='|DATABASE_URL|DB_PASSWORD|POSTGRES_PASSWORD|MYSQL_ROOT_PASSWORD)'
    
    : > "${output_file}"
    
    pushd "${repo_root}" > /dev/null 2>&1 || return 1
    
    local oid path
    while read -r oid path; do
        [[ -z "${oid}" ]] && continue
        local otype
        otype=$(git cat-file -t "${oid}" 2>/dev/null || true)
        [[ "${otype}" != "blob" ]] && continue
        
        local hits
        hits=$(git cat-file -p "${oid}" 2>/dev/null \
            | grep -anEi "${regex}" 2>/dev/null | head -20) || true
        
        if [[ -n "${hits}" ]]; then
            {
                echo "=== BLOB ${oid} (${path}) ==="
                echo "${hits}"
                echo ""
            } >> "${output_file}"
        fi
    done < <(git rev-list --objects --all 2>/dev/null)
    
    local unreachable
    unreachable=$(git fsck --full --no-reflogs --unreachable 2>/dev/null \
        | awk '/unreachable (commit|blob)/ {print $2, $3}') || true
    
    if [[ -n "${unreachable}" ]]; then
        p "#   [raw-scan] Objets orphelins trouvés"
        while read -r otype oid; do
            [[ -z "${oid}" ]] && continue
            local content
            content=$(git cat-file -p "${oid}" 2>/dev/null | head -200) || continue
            
            local hits
            hits=$(echo "${content}" | grep -anEi "${regex}" 2>/dev/null | head -20) || true
            if [[ -n "${hits}" ]]; then
                {
                    echo "=== UNREACHABLE ${otype} ${oid} ==="
                    echo "${hits}"
                    echo ""
                } >> "${output_file}"
            fi
        done <<< "${unreachable}"
    fi
    
    local -a sensitive_files=(
        ".env" ".env.local" ".env.production" "config.json" "credentials"
        "kubeconfig" "id_rsa" "id_ed25519" ".htpasswd" ".netrc"
        ".docker/config.json" "secrets.yaml" "secrets.yml" "secret.yaml"
        "values-secret.yaml" "token" "passwd"
    )
    
    for sfile in "${sensitive_files[@]}"; do
        local file_hist
        file_hist=$(git log --all --full-history --diff-filter=ACDMR \
            --format="%H|%an|%ad|%s" \
            -- "*${sfile}" "*/${sfile}" 2>/dev/null | head -10) || continue
        
        if [[ -n "${file_hist}" ]]; then
            {
                echo "=== SENSITIVE FILE: ${sfile} ==="
                echo "${file_hist}"
                local commit_hash
                commit_hash=$(echo "${file_hist}" | head -1 | cut -d'|' -f1)
                if [[ -n "${commit_hash}" ]]; then
                    echo "--- content at ${commit_hash:0:8} ---"
                    git show "${commit_hash}:**/${sfile}" 2>/dev/null \
                        | head -50 || true
                fi
                echo ""
            } >> "${output_file}"
        fi
    done
    
    local -a search_terms=("password" "secret" "token" "api_key" "credential" "bearer")
    
    for term in "${search_terms[@]}"; do
        local diff_hits
        diff_hits=$(git log --all -p -S "${term}" \
            --format="COMMIT:%H|%s" -- 2>/dev/null \
            | grep -iE "(${term}|COMMIT:)" \
            | head -30) || continue
        if [[ -n "${diff_hits}" ]]; then
            {
                echo "=== GIT LOG -S '${term}' ==="
                echo "${diff_hits}"
                echo ""
            } >> "${output_file}"
        fi
    done
    
    popd > /dev/null 2>&1 || true
    
    if [[ -s "${output_file}" ]]; then
        local line_count
        line_count=$(wc -l < "${output_file}" | tr -d ' ')
        p "#   → ${line_count} ligne(s) suspecte(s) trouvée(s)"
        return 0
    fi
    p "#   [raw-scan] RAS"
    return 1
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
p "#   📦 skopeo   - Listage et inspection des images"
p "#   🔎 gitleaks - Détection de secrets avec regex custom"
p "#   🔎 leaktk   - Détection de secrets (alternative)"
p "#   📂 git      - Recherche native dans les historiques"
p "#"
wait

p "# ======================================================================"
p "# 📋 Objectif : Détecter les secrets dans les images Docker"
p "# ======================================================================"
p "# Cette démo montre comment:"
p "#   1. Découvrir les images dans un registry"
p "#   2. Extraire les layers potentiellement dangereux"
p "#   3. Rechercher des dépôts .git exposés"
p "#   4. Scanner avec gitleaks (regex custom)"
p "#   5. Scanner avec leaktk"
p "#   6. Utiliser git directement pour chercher les secrets"
p "#"
wait

p "# ----------------------------------------------------------------------"
p "# 🔧 ÉTAPE 1: Initialisation de l'espace de travail"
p "# ----------------------------------------------------------------------"
p "# Création des répertoires temporaires..."

pe_ "mkdir -p ${REPORTS_DIR} ${CONFIG_DIR} ${EVIDENCE_DIR}"


wait

p "# ----------------------------------------------------------------------"
p "# 🔍 ÉTAPE 2: Découverte des repositories"
p "# ----------------------------------------------------------------------"
p "# Liste des images disponibles dans le registry..."

pe_ "curl -sk -u admin:xxxxxx ${REGISTRY_URL}/v2/_catalog | jq ."

wait

p ""
p "# Les repositories découverts:"
declare -a repos_array=()
mapfile -t repos_array < <(list_repositories 2>/dev/null || true)
if [[ ${#repos_array[@]} -gt 0 ]]; then
    for r in "${repos_array[@]}"; do
        [[ -n "${r}" ]] && p "   📦 ${r}"
    done
else
    p "   ⚠️ Aucun repository trouvé"
fi

wait

p "# ----------------------------------------------------------------------"
p "# 📦 ÉTAPE 3: Analyse des images et layers (approche cumulative)"
p "# ----------------------------------------------------------------------"
p "# Pour chaque image, on extrait chaque layer dans un rootfs cumulatif"
p "# et on cherche .git après chaque extraction..."

if [[ ${#repos_array[@]} -eq 0 ]]; then
    p "# ⚠️ Aucun repository trouvé"
fi

for repo in "${repos_array[@]}"; do
    [[ -z "${repo}" ]] && continue
    p ""
    p "# ======================================================================"
    p "# Image: ${repo}"
    p "# ======================================================================"
    
    p "# Tags disponibles:"
    pe_ "skopeo list-tags --tls-verify=false --creds admin:xxxxxx docker://registry.sc.local:30443/${repo} | jq ."
    
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
                
                work=$(git_work_dir "${candidate}")
                [[ -z "${work}" ]] && continue
                
                short="${digest:7:12}"
                safe_name="${repo//\//_}_${tag}_l${layer_idx}_${short}"
                
                analysis_dir="${WORK_DIR}/git-repos/${safe_name}"
                cp -a "${work}" "${analysis_dir}" 2>/dev/null || {
                    analysis_dir="${work}"
                }
                
                scan_git_repo "${candidate}" "${repo}" "${tag}" "${layer_idx}"
            done
        done
        
        if [[ -n "${layer_with_git}" ]]; then
            p "# ✅ .git trouvé dans le layer ${layer_with_git}"
        else
            p "# ℹ️ Pas de .git trouvé dans ces layers"
        fi
        
        unset seen_git
    done
done

wait

p "# ----------------------------------------------------------------------"
p "# 📊 RÉSUMÉ DE L'AUDIT"
p "# ----------------------------------------------------------------------"
p "#"
p "# Cette démo a montré les outils pour détecter:"
p "#   1. ✅ Images contenant des dépôts .git"
p "#   2. ✅ Secrets via gitleaks (regex custom)"
p "#   3. ✅ Secrets via leaktk"
p "#   4. ✅ Recherche git native (historique complet)"
p "#"
p "#"
p "# Les preuves sont stockées dans:"
p "#   ${EVIDENCE_DIR}"
p "#"
ls -la "${EVIDENCE_DIR}" 2>/dev/null || true
p "#"
p "# Pour nettoyer manuellement le répertoire de travail:"
p "#   rm -rf ${WORK_DIR}"
p "#"

p "# ======================================================================"
p "# 🎉 FIN DE LA DÉMO - Challenge 2"
p "# ======================================================================"

wait