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
SYFT_VERSION="v1.44.0"

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

p "=== DEMO : Comparaison SBOM — Détection de l'empoisonnement d'image de base ==="

# ============================================================================
# PHASE 1 — Générer le SBOM de l'image propre
# ============================================================================

p "  PHASE 1 — SBOM de l'image de base officielle (golang:1.25-alpine)"
p "1. Générer le SBOM de l'image propre depuis Docker Hub"
pe "${SYFT_CMD} scan golang:1.25-alpine -o spdx-json --file ${WORK_DIR}/sbom-clean.json"
p "2. Extraire les composants (nom + version)"
extract_packages "${WORK_DIR}/sbom-clean.json" > "${WORK_DIR}/clean-packages.txt"
pe "cat ${WORK_DIR}/clean-packages.txt"
pe "echo \"Nombre de composants dans l'image propre : \$(wc -l < ${WORK_DIR}/clean-packages.txt)\""

# ============================================================================
# PHASE 2 — Générer le SBOM de l'image empoisonnée
# ============================================================================

p "  PHASE 2 — SBOM de l'image empoisonnée dans le registre local"
p "3. Générer le SBOM de l'image empoisonnée"
pe "SSL_CERT_FILE=${CA_CERT} ${SYFT_CMD} scan ${REGISTRY_HOST}/golang:1.25-alpine -o spdx-json --file ${WORK_DIR}/sbom-poisoned.json"
p "4. Extraire les composants (nom + version)"
extract_packages "${WORK_DIR}/sbom-poisoned.json" > "${WORK_DIR}/poisoned-packages.txt"
pe "cat ${WORK_DIR}/poisoned-packages.txt"
pe "echo \"Nombre de composants dans l'image empoisonnée : \$(wc -l < ${WORK_DIR}/poisoned-packages.txt)\""

# ============================================================================
# PHASE 3 — Comparaison des SBOMs
# ============================================================================

p "  PHASE 3 — Comparaison des SBOMs"
p "5. Différence entre les packets des deux images"
pe "diff --color=always ${WORK_DIR}/clean-packages.txt ${WORK_DIR}/poisoned-packages.txt || true"

# ============================================================================
# PHASE 4 — Inspection des couches et de l'entrypoint
# ============================================================================

p "  PHASE 4 — Inspection des couches et de l'entrypoint"
p "6. Nombre de couches — image propre vs empoisonnée"
pe "echo \"Couches image propre     : \$(podman inspect golang:1.25-alpine --format '{{len .RootFS.Layers}}')\""
pe "echo \"Couches image empoisonnée: \$(podman inspect ${REGISTRY_HOST}/golang:1.25-alpine --format '{{len .RootFS.Layers}}')\""
p "7. Entrypoint — image propre"
pe "podman inspect golang:1.25-alpine --format '{{json .Config.Entrypoint}}'"
p "8. Entrypoint — image empoisonnée"
pe "skopeo inspect --config --tls-verify=false docker://${REGISTRY_HOST}/golang:1.25-alpine | jq '.config.Entrypoint'"
# p "9. Recherche de fichiers suspects dans l'image empoisonnée"
# pe "podman run --rm --entrypoint '' ${REGISTRY_HOST}/golang:1.25-alpine ls -la /usr/local/bin/backdoor.sh /etc/profile.d/init.sh 2>/dev/null || echo 'Fichiers non trouvés'"
# pe "podman run --rm --entrypoint '' ${REGISTRY_HOST}/golang:1.25-alpine cat /usr/local/bin/backdoor.sh 2>/dev/null || echo 'backdoor.sh non trouvé'"

p "✅"
