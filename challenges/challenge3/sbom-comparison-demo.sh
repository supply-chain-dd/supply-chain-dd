#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../setup/scripts/domains.sh"
REGISTRY_URL="https://${REGISTRY_HOST}"
REGISTRY_USER="sc-admin"
REGISTRY_PASS="RegistryPass123!"
CA_CERT="${SCRIPT_DIR}/../../setup/certs/registry.crt"
SYFT_VERSION="v1.45.1"

WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

INSTALLED_SYFT=$(syft version 2>/dev/null | awk '/Version:/{print "v"$2}')
if [ "$INSTALLED_SYFT" != "$SYFT_VERSION" ]; then
  echo "Downloading Syft ${SYFT_VERSION}..."
  ARCH="amd64"; case "$(uname -m)" in aarch64|arm64) ARCH="arm64" ;; esac
  curl -sSfL "https://github.com/anchore/syft/releases/download/${SYFT_VERSION}/syft_${SYFT_VERSION#v}_linux_${ARCH}.tar.gz" \
    | tar xz -C "${WORK_DIR}" syft
  SYFT_CMD="${WORK_DIR}/syft"
else
  SYFT_CMD="syft"
fi

# Helper: extract "SPDXID | purl" sorted list from SPDX JSON
extract_packages() {
    jq -r '.packages[] | "\(.SPDXID) | \(.externalRefs[]? | select(.referenceType == "purl") | .referenceLocator)"' "$1" | sort
}

p "=== DEMO :SBOM en détective ==="

# ============================================================================
# PHASE 1 — Générer les SBOMs des images propres
# ============================================================================

p "  PHASE 1 — SBOMs des images de base officielles"

# p "1. Générer le SBOM de golang:1.25-alpine depuis Docker Hub"
pe "${SYFT_CMD} scan golang:1.25-alpine -o spdx-json --file ${WORK_DIR}/sbom-golang-clean.json"

p "1. À quoi ressemble un SBOM SPDX ? Voici les métadonnées et les 3 premiers paquets"
pe "cat ${WORK_DIR}/sbom-golang-clean.json | jq | head -70"

p "2. Extraire les composants golang (nom + version)"
extract_packages "${WORK_DIR}/sbom-golang-clean.json" > "${WORK_DIR}/golang-clean-packages.txt"
pe "cat ${WORK_DIR}/golang-clean-packages.txt"
# pe "echo \"Nombre de composants dans golang propre : \$(wc -l < ${WORK_DIR}/golang-clean-packages.txt)\""

p "3. Même chose pour alpine:3.20 (image runtime)"
pe "${SYFT_CMD} scan alpine:3.20 -o spdx-json --file ${WORK_DIR}/sbom-alpine-clean.json"
extract_packages "${WORK_DIR}/sbom-alpine-clean.json" > "${WORK_DIR}/alpine-clean-packages.txt"
# pe "echo \"Nombre de composants dans alpine propre : \$(wc -l < ${WORK_DIR}/alpine-clean-packages.txt)\""

# ============================================================================
# PHASE 2 — Comparaison des SBOMs (registre local vs Docker Hub)
# ============================================================================

p "  PHASE 2 — Comparaison des SBOMs : Docker Hub vs registre local"

p "4. Génération des SBOMs depuis le registre local..."
echo "  Scan de ${REGISTRY_HOST}/golang:1.25-alpine..."
SSL_CERT_FILE=${CA_CERT} ${SYFT_CMD} scan ${REGISTRY_HOST}/golang:1.25-alpine -o spdx-json --file ${WORK_DIR}/sbom-golang-poisoned.json 2>/dev/null
extract_packages "${WORK_DIR}/sbom-golang-poisoned.json" > "${WORK_DIR}/golang-poisoned-packages.txt"
echo "  Scan de ${REGISTRY_HOST}/alpine:3.20..."
SSL_CERT_FILE=${CA_CERT} ${SYFT_CMD} scan ${REGISTRY_HOST}/alpine:3.20 -o spdx-json --file ${WORK_DIR}/sbom-alpine-poisoned.json 2>/dev/null
extract_packages "${WORK_DIR}/sbom-alpine-poisoned.json" > "${WORK_DIR}/alpine-poisoned-packages.txt"
echo "  Fait."

p "5. Différence SBOM golang : Docker Hub vs registre local"
pe "diff --color=always ${WORK_DIR}/golang-clean-packages.txt ${WORK_DIR}/golang-poisoned-packages.txt || true"

p "6. Différence SBOM alpine : Docker Hub vs registre local"
pe "diff --color=always ${WORK_DIR}/alpine-clean-packages.txt ${WORK_DIR}/alpine-poisoned-packages.txt || true"

# ============================================================================
# PHASE 3 — Comparaison des configurations de conteneur
# ============================================================================

p "  PHASE 3 — Comparaison des configurations de conteneur"

# p "8. Différence de configuration golang"
# skopeo inspect --config docker://golang:1.25-alpine 2>/dev/null | jq --sort-keys '.config' > ${WORK_DIR}/golang-clean-config.json
# skopeo inspect --config --tls-verify=false docker://${REGISTRY_HOST}/golang:1.25-alpine 2>/dev/null | jq --sort-keys '.config' > ${WORK_DIR}/golang-poisoned-config.json
# pe "diff --color=always ${WORK_DIR}/golang-clean-config.json ${WORK_DIR}/golang-poisoned-config.json || true"

p "7. Différence de configuration alpine"
skopeo inspect --config docker://alpine:3.20 2>/dev/null | jq --sort-keys '.config' > ${WORK_DIR}/alpine-clean-config.json
skopeo inspect --config --tls-verify=false docker://${REGISTRY_HOST}/alpine:3.20 2>/dev/null | jq --sort-keys '.config' > ${WORK_DIR}/alpine-poisoned-config.json
pe "diff --color=always ${WORK_DIR}/alpine-clean-config.json ${WORK_DIR}/alpine-poisoned-config.json || true"

p "✅"
