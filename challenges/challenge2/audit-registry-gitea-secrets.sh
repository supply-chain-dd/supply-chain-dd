#!/usr/bin/env bash

################################################################################
# audit-registry-git-secrets.sh
#
# Script d'audit de sécurité pour rechercher des secrets dans les répertoires
# .git embarqués dans les layers d'images d'une registry OCI/Docker locale.
#
# Utilise demo-magic pour la présentation interactive.
# Utilise skopeo pour l'interaction avec la registry.
#
# Contexte : Kubernetes, Kind, Tekton, ArgoCD, Gitea, Conforma, Sigstore
################################################################################

set -eo pipefail

########################
# CONFIGURATION
########################

REGISTRY_URL="https://registry.sc.local:30443"
REGISTRY_USER="admin"
REGISTRY_PASS="RegisterPass123!"
REGISTRY_HOST="registry.sc.local:30443"

WORK_DIR="/tmp/audit-registry-secrets"
LAYERS_DIR="${WORK_DIR}/layers"
ROOTFS_DIR="${WORK_DIR}/rootfs"
GIT_REPOS_DIR="${WORK_DIR}/git-repos"
REPORTS_DIR="${WORK_DIR}/reports"
TOOLS_DIR="${WORK_DIR}/tools"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${REPORTS_DIR}/audit_report_${TIMESTAMP}.md"
FINDINGS_FILE="${REPORTS_DIR}/findings_${TIMESTAMP}.json"

########################
# DEMO-MAGIC
########################

install_demo_magic() {
    local dm_path="${TOOLS_DIR}/demo-magic.sh"

    if [[ ! -f "${dm_path}" ]]; then
        echo -e "${YELLOW}[*] Installation de demo-magic...${NC}"
        mkdir -p "${TOOLS_DIR}"
        curl -fsSL \
            "https://raw.githubusercontent.com/paxtonhare/demo-magic/master/demo-magic.sh" \
            -o "${dm_path}" 2>/dev/null || {
            echo -e "${RED}[!] Impossible de télécharger demo-magic.${NC}"
            exit 1
        }
        chmod +x "${dm_path}"
        echo -e "${GREEN}[✓] demo-magic installé.${NC}"
    fi

    # shellcheck source=/dev/null
    source "${dm_path}"

    export TYPE_SPEED=1000
    export DEMO_PROMPT="${GREEN}audit ${CYAN}\$ ${NC}"

    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        export NO_WAIT=true
        export TYPE_SPEED=0
    fi

    # Ouvrir /dev/tty sur fd 9 pour que demo-magic fonctionne
    # même dans des boucles ou sous WSL
    if [[ -r /dev/tty ]]; then
        exec 9</dev/tty
        echo -e "${GREEN}[✓] demo-magic prêt (fd 9 → /dev/tty).${NC}"
    else
        echo -e "${YELLOW}[!] /dev/tty inaccessible → mode non-interactif.${NC}"
        export NO_WAIT=true
        export TYPE_SPEED=0
    fi
}

########################
# WRAPPERS DEMO-MAGIC (sans pv / instantané)
########################

dm_p() {
    echo ""
    echo -e "${BOLD}${BLUE}$*${NC}"
    echo ""
}

dm_pe() {
    echo -e "${GREEN}audit ${CYAN}\$ ${NC}$*"
    
    if [[ "${NO_WAIT:-}" != "true" ]]; then
        if [[ -r /dev/tty ]]; then
            read -rs < /dev/tty
        else
            read -rs
        fi
    fi
    
    eval "$@||true"
}

########################
# VÉRIFICATION DES DÉPENDANCES
########################

check_and_install_tools() {
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   VÉRIFICATION DES OUTILS NÉCESSAIRES                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    local missing=()

    # --- skopeo ---
    if ! command -v skopeo &>/dev/null; then
        echo -e "${YELLOW}[*] skopeo non trouvé, installation...${NC}"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq skopeo
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q skopeo
        else
            missing+=("skopeo")
        fi
    fi
    command -v skopeo &>/dev/null \
        && echo -e "${GREEN}[✓] skopeo : $(skopeo --version 2>/dev/null)${NC}" \
        || echo -e "${RED}[✗] skopeo${NC}"

    # --- jq ---
    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}[*] jq non trouvé, installation...${NC}"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq jq
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q jq
        else
            missing+=("jq")
        fi
    fi
    command -v jq &>/dev/null \
        && echo -e "${GREEN}[✓] jq : $(jq --version 2>/dev/null)${NC}" \
        || echo -e "${RED}[✗] jq${NC}"

    # --- curl ---
    if ! command -v curl &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq curl
        else
            missing+=("curl")
        fi
    fi
    command -v curl &>/dev/null \
        && echo -e "${GREEN}[✓] curl${NC}" \
        || echo -e "${RED}[✗] curl${NC}"

    # --- git ---
    if ! command -v git &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq git
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q git
        else
            missing+=("git")
        fi
    fi
    command -v git &>/dev/null \
        && echo -e "${GREEN}[✓] git : $(git --version 2>/dev/null)${NC}" \
        || echo -e "${RED}[✗] git${NC}"

    # --- file ---
    if ! command -v file &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq file
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q file
        fi
    fi
    command -v file &>/dev/null \
        && echo -e "${GREEN}[✓] file${NC}" \
        || echo -e "${YELLOW}[~] file${NC}"

    # --- zstd ---
    if ! command -v zstd &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq zstd
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q zstd
        fi
    fi
    command -v zstd &>/dev/null \
        && echo -e "${GREEN}[✓] zstd${NC}" \
        || echo -e "${YELLOW}[~] zstd${NC}"

    # --- trufflehog ---
    if ! command -v trufflehog &>/dev/null; then
        echo -e "${YELLOW}[*] trufflehog non trouvé, installation...${NC}"
        local th_version="3.82.13" os arch
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        arch=$(uname -m)
        case "${arch}" in
            x86_64)        arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
        esac
        mkdir -p "${TOOLS_DIR}"
        curl -fsSL \
            "https://github.com/trufflesecurity/trufflehog/releases/download/v${th_version}/trufflehog_${th_version}_${os}_${arch}.tar.gz" \
            2>/dev/null | tar xz -C "${TOOLS_DIR}" trufflehog 2>/dev/null || true
        if [[ -f "${TOOLS_DIR}/trufflehog" ]]; then
            sudo cp "${TOOLS_DIR}/trufflehog" /usr/local/bin/trufflehog 2>/dev/null || true
            chmod +x /usr/local/bin/trufflehog 2>/dev/null || true
            [[ ! -x /usr/local/bin/trufflehog ]] && export PATH="${TOOLS_DIR}:${PATH}"
        fi
    fi
    command -v trufflehog &>/dev/null \
        && echo -e "${GREEN}[✓] trufflehog : $(trufflehog --version 2>/dev/null)${NC}" \
        || echo -e "${YELLOW}[~] trufflehog (analyse dégradée)${NC}"

    # --- gitleaks ---
    if ! command -v gitleaks &>/dev/null; then
        echo -e "${YELLOW}[*] gitleaks non trouvé, installation...${NC}"
        local gl_version="8.21.2" os arch
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        arch=$(uname -m)
        case "${arch}" in
            x86_64)        arch="x64"  ;;
            aarch64|arm64) arch="arm64" ;;
        esac
        mkdir -p "${TOOLS_DIR}"
        curl -fsSL \
            "https://github.com/gitleaks/gitleaks/releases/download/v${gl_version}/gitleaks_${gl_version}_${os}_${arch}.tar.gz" \
            2>/dev/null | tar xz -C "${TOOLS_DIR}" gitleaks 2>/dev/null || true
        if [[ -f "${TOOLS_DIR}/gitleaks" ]]; then
            sudo cp "${TOOLS_DIR}/gitleaks" /usr/local/bin/gitleaks 2>/dev/null || true
            chmod +x /usr/local/bin/gitleaks 2>/dev/null || true
            [[ ! -x /usr/local/bin/gitleaks ]] && export PATH="${TOOLS_DIR}:${PATH}"
        fi
    fi
    command -v gitleaks &>/dev/null \
        && echo -e "${GREEN}[✓] gitleaks : $(gitleaks version 2>/dev/null)${NC}" \
        || echo -e "${YELLOW}[~] gitleaks (analyse dégradée)${NC}"

    echo ""
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}[!] Outils critiques manquants : ${missing[*]}${NC}"
        exit 1
    fi
    echo -e "${GREEN}${BOLD}[✓] Tous les outils critiques sont disponibles.${NC}"
    echo ""
}

########################
# INITIALISATION
########################

init_workspace() {
    echo -e "${BLUE}[*] Initialisation workspace : ${WORK_DIR}${NC}" >&2
    rm -rf "${WORK_DIR}"
    mkdir -p "${LAYERS_DIR}" "${ROOTFS_DIR}" "${GIT_REPOS_DIR}" \
             "${REPORTS_DIR}" "${TOOLS_DIR}"

    cat > "${REPORT_FILE}" <<EOF
# 🔍 Rapport d'Audit - Registry Container Images

- **Date** : $(date -u +"%Y-%m-%d %H:%M:%S UTC")
- **Registry** : ${REGISTRY_URL}
- **Auditeur** : $(whoami)@$(hostname)
- **Contexte** : Kubernetes, Kind, Tekton, ArgoCD, Gitea, Conforma, Sigstore

---

EOF

    echo '{"findings":[],"metadata":{"registry":"'"${REGISTRY_URL}"'","timestamp":"'"${TIMESTAMP}"'"}}' \
        | jq '.' > "${FINDINGS_FILE}"

    echo -e "${GREEN}[✓] Workspace prêt.${NC}" >&2
}

########################
# FONCTIONS SKOPEO
# Tous les logs → stderr pour ne pas polluer stdout
########################

skopeo_creds() {
    echo "${REGISTRY_USER}:${REGISTRY_PASS}"
}

# Lister tous les repositories via skopeo + curl fallback
list_repositories() {
    echo -e "${BLUE}[*] Listing des repositories (skopeo/curl)...${NC}" >&2

    # skopeo ne supporte pas "list repos" directement
    # On utilise l'API catalog via curl
    local repos
    repos=$(curl -fsSL --insecure \
        -u "$(skopeo_creds)" \
        "${REGISTRY_URL}/v2/_catalog" 2>/dev/null \
        | jq -r '.repositories[]?' 2>/dev/null) || {
        echo -e "${RED}[!] Impossible de lister les repositories.${NC}" >&2
        return 1
    }

    if [[ -z "${repos}" ]]; then
        echo -e "${RED}[!] Aucun repository trouvé.${NC}" >&2
        return 1
    fi

    # Seule sortie stdout = les données
    echo "${repos}"
}

# Lister les tags d'un repo via skopeo
list_tags() {
    local repo="$1"
    echo -e "${BLUE}[*] Listing des tags pour ${repo}...${NC}" >&2

    local tags_json
    tags_json=$(skopeo list-tags \
        --tls-verify=false \
        --creds "$(skopeo_creds)" \
        "docker://${REGISTRY_HOST}/${repo}" 2>/dev/null) || {
        echo -e "${YELLOW}[!] Échec skopeo list-tags pour ${repo}${NC}" >&2
        return 1
    }

    echo "${tags_json}" | jq -r '.Tags[]?' 2>/dev/null
}

# Inspecter une image avec skopeo et récupérer les digests des layers
get_layer_digests() {
    local repo="$1"
    local tag="$2"
    echo -e "${BLUE}[*] Inspection de ${repo}:${tag} via skopeo...${NC}" >&2

    local inspect_json
    inspect_json=$(skopeo inspect \
        --tls-verify=false \
        --creds "$(skopeo_creds)" \
        "docker://${REGISTRY_HOST}/${repo}:${tag}" 2>/dev/null) || {
        echo -e "${YELLOW}[!] Échec skopeo inspect pour ${repo}:${tag}${NC}" >&2
        return 1
    }

    # Extraire les digests des layers
    local digests
    digests=$(echo "${inspect_json}" | jq -r '.Layers[]?' 2>/dev/null) || true

    # Si .Layers est vide, essayer .LayersData
    if [[ -z "${digests}" ]]; then
        digests=$(echo "${inspect_json}" | jq -r '.LayersData[]?.Digest' 2>/dev/null) || true
    fi

    if [[ -z "${digests}" ]]; then
        echo -e "${YELLOW}[!] Aucun layer trouvé pour ${repo}:${tag}${NC}" >&2
        echo -e "${YELLOW}[*] Inspect brut :${NC}" >&2
        echo "${inspect_json}" | jq '.' >&2 || echo "${inspect_json}" >&2
        return 1
    fi

    echo "${digests}"
}

# Télécharger un blob (layer) depuis la registry
download_blob() {
    local repo="$1"
    local digest="$2"
    local output_file="$3"

    local auth
    auth=$(printf '%s' "${REGISTRY_USER}:${REGISTRY_PASS}" | base64 | tr -d '\n')

    echo -e "${CYAN}    [↓] Téléchargement ${digest:0:25}...${NC}" >&2

    curl -fsSL \
        --insecure \
        -H "Authorization: Basic ${auth}" \
        -o "${output_file}" \
        "${REGISTRY_URL}/v2/${repo}/blobs/${digest}" 2>/dev/null
}

# Extraire un layer (gzip / tar / zstd)
extract_layer() {
    local blob_file="$1"
    local extract_dir="$2"

    mkdir -p "${extract_dir}"

    local file_type
    file_type=$(file -b "${blob_file}" 2>/dev/null || echo "unknown")
    echo -e "${CYAN}    [*] Type : ${file_type:0:40}${NC}" >&2

    if echo "${file_type}" | grep -qi 'zstandard'; then
        zstd -dc "${blob_file}" 2>/dev/null | tar -xf - -C "${extract_dir}" 2>/dev/null
    elif echo "${file_type}" | grep -qi 'gzip'; then
        gzip -dc "${blob_file}" 2>/dev/null | tar -xf - -C "${extract_dir}" 2>/dev/null
    elif echo "${file_type}" | grep -qi 'tar'; then
        tar -xf "${blob_file}" -C "${extract_dir}" 2>/dev/null
    else
        # Essayer tout
        gzip -dc "${blob_file}" 2>/dev/null | tar -xf - -C "${extract_dir}" 2>/dev/null || \
        tar -xf "${blob_file}" -C "${extract_dir}" 2>/dev/null || \
        zstd -dc "${blob_file}" 2>/dev/null | tar -xf - -C "${extract_dir}" 2>/dev/null || {
            echo -e "${YELLOW}    [!] Extraction échouée${NC}" >&2
            return 1
        }
    fi
}

# Chercher des candidats .git (dossier, fichier, bare repo)
find_git_candidates() {
    local search_dir="$1"
    {
        find "${search_dir}" -type d -name ".git" 2>/dev/null
        find "${search_dir}" -type f -name ".git" 2>/dev/null
        find "${search_dir}" -type d -name "*.git" \
            -exec test -f '{}/HEAD' \; -print 2>/dev/null
    } | sort -u
}

########################
# ANALYSE GIT
########################

# Déterminer le répertoire de travail git
git_work_dir() {
    local candidate="$1"
    local base
    base=$(basename "${candidate}")

    if [[ "${base}" == ".git" ]]; then
        if [[ -d "${candidate}" ]]; then
            # .git est un dossier → parent = repo root
            dirname "${candidate}"
        elif [[ -f "${candidate}" ]]; then
            # .git est un fichier → lire gitdir
            dirname "${candidate}"
        fi
    elif [[ -d "${candidate}" && -f "${candidate}/HEAD" ]]; then
        # bare repo
        echo "${candidate}"
    fi
}

# Analyse avec trufflehog
analyze_trufflehog() {
    local repo_root="$1"
    local output_file="$2"

    command -v trufflehog &>/dev/null || return 1

    echo -e "${CYAN}      [trufflehog] Analyse...${NC}" >&2
    trufflehog git "file://${repo_root}" --json --no-update \
        2>/dev/null > "${output_file}" || true

    local count
    count=$(wc -l < "${output_file}" 2>/dev/null | tr -d ' ')
    if [[ "${count}" -gt 0 ]]; then
        echo -e "${RED}      [trufflehog] ⚠️  ${count} secret(s) !${NC}" >&2
        return 0
    fi
    echo -e "${GREEN}      [trufflehog] RAS.${NC}" >&2
    return 1
}

# Analyse avec gitleaks
analyze_gitleaks() {
    local repo_root="$1"
    local output_file="$2"

    command -v gitleaks &>/dev/null || return 1

    echo -e "${CYAN}      [gitleaks] Analyse...${NC}" >&2
    gitleaks detect \
        --source="${repo_root}" \
        --report-format=json \
        --report-path="${output_file}" \
        --no-banner 2>/dev/null || true

    if [[ -f "${output_file}" && -s "${output_file}" ]]; then
        local count
        count=$(jq 'length' "${output_file}" 2>/dev/null || echo "0")
        if [[ "${count}" -gt 0 ]]; then
            echo -e "${RED}      [gitleaks] ⚠️  ${count} secret(s) !${NC}" >&2
            return 0
        fi
    fi
    echo -e "${GREEN}      [gitleaks] RAS.${NC}" >&2
    return 1
}

# Scan brut des objets git (tous les blobs, y compris orphelins)
scan_git_raw() {
    local repo_root="$1"
    local output_file="$2"

    echo -e "${CYAN}      [raw-scan] Analyse de tous les objets git...${NC}" >&2

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

    # 1. Tous les objets référencés
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

    # 2. Commits orphelins / supprimés
    local unreachable
    unreachable=$(git fsck --full --no-reflogs --unreachable 2>/dev/null \
        | awk '/unreachable (commit|blob)/ {print $2, $3}') || true

    if [[ -n "${unreachable}" ]]; then
        echo -e "${YELLOW}      [raw-scan] Objets orphelins trouvés${NC}" >&2
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

    # 3. Fichiers sensibles dans l'historique
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
                # Extraire le contenu depuis le premier commit
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

    # 4. Recherche dans les diffs de tous les commits
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
        echo -e "${RED}      [raw-scan] ⚠️  ${line_count} ligne(s) suspecte(s) !${NC}" >&2
        return 0
    fi
    echo -e "${GREEN}      [raw-scan] RAS.${NC}" >&2
    return 1
}

########################
# ENREGISTREMENT DES FINDINGS
########################

record_finding() {
    local image="$1" layer="$2" git_path="$3" tool="$4"
    local details_file="$5" severity="${6:-HIGH}"

    cat >> "${REPORT_FILE}" <<EOF

### 🚨 Finding - ${severity}
- **Image** : \`${image}\`
- **Layer** : \`${layer:0:30}...\`
- **Chemin .git** : \`${git_path}\`
- **Outil** : ${tool}

<details><summary>Détails</summary>

\`\`\`
$(head -100 "${details_file}" 2>/dev/null)
\`\`\`
</details>

---
EOF

    local tmp_json
    tmp_json=$(mktemp)
    jq --arg image "${image}" \
       --arg layer "${layer}" \
       --arg path "${git_path}" \
       --arg tool "${tool}" \
       --arg severity "${severity}" \
       --arg details "$(head -500 "${details_file}" 2>/dev/null)" \
       '.findings += [{
           "image":$image,"layer":$layer,"git_path":$path,
           "tool":$tool,"severity":$severity,"details":$details
       }]' "${FINDINGS_FILE}" > "${tmp_json}" 2>/dev/null \
    && mv "${tmp_json}" "${FINDINGS_FILE}" \
    || rm -f "${tmp_json}"
}

########################
# AUDIT PRINCIPAL
########################

audit_registry() {
    local total_findings=0 total_images=0 total_layers=0 total_git=0

    #──────────────────────────────────────────────────────────────────
    # ÉTAPE 1 : Connexion et listing
    #──────────────────────────────────────────────────────────────────
    dm_p "# ═══ Étape 1 : Connexion à la registry et listing ═══"
    dm_pe "skopeo login --tls-verify=false --username ${REGISTRY_USER} --password ${REGISTRY_PASS} ${REGISTRY_HOST}"

    dm_p "# Listing des repositories"
    dm_pe "curl -s -u ${REGISTRY_USER}:${REGISTRY_PASS} ${REGISTRY_URL}/v2/_catalog | jq ."

    local -a repos_array=()
    mapfile -t repos_array < <(list_repositories)

    if [[ ${#repos_array[@]} -eq 0 ]]; then
        echo -e "${RED}[!] Aucun repository trouvé.${NC}"
        return 1
    fi

    echo -e "${GREEN}[✓] ${#repos_array[@]} repository(ies) :${NC}"
    printf '    %s\n' "${repos_array[@]}"
    echo ""

    #──────────────────────────────────────────────────────────────────
    # ÉTAPE 2 : Analyse de chaque image
    #──────────────────────────────────────────────────────────────────
    dm_p "# ═══ Étape 2 : Analyse des images ═══"

    for repo in "${repos_array[@]}"; do
        [[ -z "${repo}" ]] && continue

        echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"
        echo -e "${BOLD}${BLUE}  Repository : ${repo}${NC}"
        echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"

        dm_pe "skopeo list-tags --tls-verify=false --creds ${REGISTRY_USER}:${REGISTRY_PASS} docker://${REGISTRY_HOST}/${repo}"

        local -a tags_array=()
        mapfile -t tags_array < <(list_tags "${repo}" 2>/dev/null || true)

        if [[ ${#tags_array[@]} -eq 0 ]]; then
            echo -e "${YELLOW}  [!] Aucun tag.${NC}"
            continue
        fi

        for tag in "${tags_array[@]}"; do
            [[ -z "${tag}" ]] && continue
            total_images=$((total_images + 1))

            local image_ref="${repo}:${tag}"

            echo -e "\n${CYAN}  📦 Image : ${image_ref}${NC}"

            dm_pe "skopeo inspect --tls-verify=false --creds ${REGISTRY_USER}:${REGISTRY_PASS} docker://${REGISTRY_HOST}/${image_ref} | jq '{Layers, LayersData}'"

            # Récupérer les digests
            local -a digests_array=()
            mapfile -t digests_array < <(get_layer_digests "${repo}" "${tag}" 2>/dev/null || true)

            if [[ ${#digests_array[@]} -eq 0 ]]; then
                echo -e "${YELLOW}    [!] Aucun layer.${NC}"
                continue
            fi

            echo -e "${GREEN}    [✓] ${#digests_array[@]} layer(s)${NC}"

            # Rootfs cumulatif pour cette image
            local image_rootfs="${ROOTFS_DIR}/${repo//\//_}/${tag}"
            rm -rf "${image_rootfs}"
            mkdir -p "${image_rootfs}"

            # Tracker les .git déjà vus
            declare -A seen_git=()

            local layer_index=0
            for digest in "${digests_array[@]}"; do
                [[ -z "${digest}" ]] && continue
                layer_index=$((layer_index + 1))
                total_layers=$((total_layers + 1))

                local short="${digest:7:12}"
                echo -e "${CYAN}    📋 Layer ${layer_index}/${#digests_array[@]} [${short}]${NC}"

                local blob_file="${LAYERS_DIR}/blob_${repo//\//_}_${tag}_${layer_index}"

                # Télécharger
                if ! download_blob "${repo}" "${digest}" "${blob_file}"; then
                    echo -e "${YELLOW}    [!] Échec téléchargement${NC}"
                    continue
                fi

                # Extraire dans rootfs cumulatif
                if ! extract_layer "${blob_file}" "${image_rootfs}"; then
                    echo -e "${YELLOW}    [!] Échec extraction${NC}"
                    rm -f "${blob_file}"
                    continue
                fi
                rm -f "${blob_file}"

                # Chercher les candidats .git
                local -a git_candidates=()
                mapfile -t git_candidates < <(find_git_candidates "${image_rootfs}")

                if [[ ${#git_candidates[@]} -eq 0 ]]; then
                    echo -e "${GREEN}    ✓ Pas de .git après ce layer.${NC}"
                    continue
                fi

                for candidate in "${git_candidates[@]}"; do
                    [[ -z "${candidate}" ]] && continue

                    # Éviter de ré-analyser le même .git
                    if [[ -n "${seen_git[${candidate}]:-}" ]]; then
                        continue
                    fi
                    seen_git["${candidate}"]=1
                    total_git=$((total_git + 1))

                    echo -e "${YELLOW}    ⚠️  .git trouvé : ${candidate}${NC}"

                    dm_pe "echo '    Analyse de ${candidate}'"

                    # Déterminer le répertoire de travail
                    local work
                    work=$(git_work_dir "${candidate}")
                    [[ -z "${work}" ]] && continue

                    local safe_name="${repo//\//_}_${tag}_l${layer_index}_${short}"

                    # Copier pour analyse sans altérer le rootfs
                    local analysis_dir="${GIT_REPOS_DIR}/${safe_name}"
                    cp -a "${work}" "${analysis_dir}" 2>/dev/null || {
                        analysis_dir="${work}"
                    }

                    echo -e "${CYAN}      Analyse dans : ${analysis_dir}${NC}"

                    # --- trufflehog ---
                    local th_out="${REPORTS_DIR}/trufflehog_${safe_name}.json"
                    if analyze_trufflehog "${analysis_dir}" "${th_out}"; then
                        total_findings=$((total_findings + 1))
                        record_finding "${image_ref}" "${digest}" \
                            "${candidate}" "trufflehog" "${th_out}" "CRITICAL"

                        dm_pe "cat ${th_out} | jq '{SourceMetadata,Raw,RawV2}' 2>/dev/null | head -30"
                    fi

                    # --- gitleaks ---
                    local gl_out="${REPORTS_DIR}/gitleaks_${safe_name}.json"
                    if analyze_gitleaks "${analysis_dir}" "${gl_out}"; then
                        total_findings=$((total_findings + 1))
                        record_finding "${image_ref}" "${digest}" \
                            "${candidate}" "gitleaks" "${gl_out}" "CRITICAL"

                        dm_pe "cat ${gl_out} | jq '.[].Secret' 2>/dev/null | head -20"
                    fi

                    # --- scan brut git ---
                    local raw_out="${REPORTS_DIR}/rawgit_${safe_name}.txt"
                    if scan_git_raw "${analysis_dir}" "${raw_out}"; then
                        total_findings=$((total_findings + 1))
                        record_finding "${image_ref}" "${digest}" \
                            "${candidate}" "raw-git-scan" "${raw_out}" "HIGH"

                        dm_pe "head -50 ${raw_out}"
                    fi

                    # --- Affichage interactif de l'historique ---
                    dm_p "# Historique git complet :"
                    dm_pe "cd ${analysis_dir} && git log --oneline --all --graph 2>/dev/null || true"
                    dm_pe "cd ${analysis_dir} && git log --all -p -S 'token' --format='%H %s' 2>/dev/null | head -40 || true"
                    dm_pe "cd ${analysis_dir} && git log --all -p -S 'password' --format='%H %s' 2>/dev/null | head -40 || true"
                    dm_pe "cd ${analysis_dir} && git log --all -p -S 'secret' --format='%H %s' 2>/dev/null | head -40 || true"
                    dm_pe "cd ${analysis_dir} && git fsck --unreachable --no-reflogs 2>/dev/null | head -20 || true"

                done
            done

            # Nettoyer le rootfs de cette image
            unset seen_git
        done
    done

    #──────────────────────────────────────────────────────────────────
    # ÉTAPE 3 : Résumé
    #──────────────────────────────────────────────────────────────────
    dm_p "# ═══ Étape 3 : Résumé de l'audit ═══"

    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                   RÉSUMÉ DE L'AUDIT                         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║  %-56s  ║\n" "Images analysées          : ${total_images}"
    printf "║  %-56s  ║\n" "Layers analysés           : ${total_layers}"
    printf "║  %-56s  ║\n" "Répertoires .git trouvés  : ${total_git}"

    if [[ ${total_findings} -gt 0 ]]; then
        echo -e "║  ${RED}Secrets/findings trouvés  : ${total_findings}${NC}${BOLD}$(printf '%30s' '')  ║"
    else
        printf "║  %-56s  ║\n" "Secrets/findings trouvés  : ${total_findings}"
    fi
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║  %-56s  ║\n" "Rapport : ${REPORT_FILE}"
    printf "║  %-56s  ║\n" "JSON    : ${FINDINGS_FILE}"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ ${total_findings} -gt 0 ]]; then
        echo -e "${RED}${BOLD}⚠️  DES SECRETS ONT ÉTÉ TROUVÉS !${NC}"
        echo ""
        dm_pe "jq '.findings[] | {image, tool, severity, git_path}' ${FINDINGS_FILE}"
        dm_pe "cat ${REPORT_FILE}"
    else
        echo -e "${GREEN}${BOLD}✓ Aucun secret trouvé.${NC}"
    fi

    # Finaliser le rapport
    cat >> "${REPORT_FILE}" <<EOF

## Statistiques

| Métrique | Valeur |
|----------|--------|
| Images analysées | ${total_images} |
| Layers analysés | ${total_layers} |
| .git trouvés | ${total_git} |
| **Findings** | **${total_findings}** |

---
*Généré par audit-registry-git-secrets.sh — ${TIMESTAMP}*
EOF

    dm_pe "echo 'Rapport : ${REPORT_FILE}'"
    dm_pe "echo 'JSON    : ${FINDINGS_FILE}'"

    return ${total_findings}
}

########################
# POINT D'ENTRÉE
########################

main() {
    echo -e "${BOLD}${RED}"
    cat << 'BANNER'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║   🔍  AUDIT DE SÉCURITÉ - REGISTRY CONTAINER IMAGES              ║
    ║                                                                   ║
    ║   Recherche de .git dans les layers + extraction de secrets       ║
    ║   via skopeo + trufflehog + gitleaks + scan brut                 ║
    ║                                                                   ║
    ║   Contexte : K8s / Kind / Tekton / ArgoCD / Gitea / Sigstore     ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) export NON_INTERACTIVE=true; shift ;;
            --help|-h)
                echo "Usage: $0 [--non-interactive] [--help]"
                exit 0 ;;
            *) echo "Option inconnue: $1"; exit 1 ;;
        esac
    done

    echo -e "${BLUE}Configuration :${NC}"
    echo "  Registry : ${REGISTRY_URL}"
    echo "  User     : ${REGISTRY_USER}"
    echo "  Host     : ${REGISTRY_HOST}"
    echo ""

    install_demo_magic
    check_and_install_tools
    init_workspace
    audit_registry

    echo ""
    echo -e "${BOLD}${GREEN}[✓] Audit terminé.${NC}"
    echo ""
}

main "$@"
