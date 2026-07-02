#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../setup/scripts/domains.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY_CA="${REPO_ROOT}/setup/certs/registry.crt"
REGISTRY_URL="${REGISTRY_HOST}"
IMAGE_NAME="recipe-api"
IMAGE_TAG="v2.0-keyless"
IMAGE_REF="${REGISTRY_URL}/${IMAGE_NAME}:${IMAGE_TAG}"

if ! command -v cosign &>/dev/null; then
    echo "cosign non installé. Voir : https://docs.sigstore.dev/cosign/installation/"
    exit 1
fi

if ! command -v tkn &>/dev/null; then
    echo "tkn CLI non trouvé. Installer avec : make -C ${REPO_ROOT} install-tkn"
    echo "   Les logs du pipeline ne seront pas affichés en temps réel."
fi

# --- URLs des services Sigstore via NodePort ---
REKOR_URL_LOCAL="http://${REKOR_HOST}"
TUF_MIRROR_LOCAL="http://${TUF_HOST}"

source "${SCRIPT_DIR}/../../setup/scripts/check-sigstore.sh"
check_tuf_root

cleanup() {
    [ -n "${TUF_ROOT_FILE:-}" ] && rm -f "${TUF_ROOT_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

p "=== Signature Keyless d'images — Cosign + Fulcio/Rekor local ==="

# ============================================================================
# SECTION 1 — Stack Sigstore locale
# ============================================================================

# pe "kubectl get pods -n fulcio-system"
# p "Fulcio est l'autorité de certification — émet des certificats de signature éphémères"

# pe "kubectl get pods -n rekor-system"
# p "Rekor est le transparency log — enregistre chaque événement de signature de façon immuable"

# pe "kubectl get pods -n tuf-system"
# p "TUF distribue la racine de confiance pour vérifier Fulcio/Rekor"

pe "make -C ${REPO_ROOT} setup-challenge2-tekton-keyless"

p "Déclenchement du pipeline de signature keyless..."

pe "kubectl create -f ${SCRIPT_DIR}/tekton/manual-pipelinerun-keyless.yaml"
# # ============================================================================
# # SECTION 2 — Identité OIDC
# # ============================================================================

# p "La pipeline utilise un ServiceAccount dédié : pipeline-keyless-signer"

# pe "kubectl get serviceaccount pipeline-keyless-signer -n ci -o yaml | head -20"

# p "L'OIDC issuer du cluster est utilisé par Fulcio pour vérifier le token du SA :"
# pe "kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer'"

ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')

# # ============================================================================
# # SECTION 3 — Token ServiceAccount projeté
# # ============================================================================

# p "  SECTION 3 — Token ServiceAccount projeté"
# p "La tâche sign-image-keyless monte un token SA projeté comme identité OIDC :"

# pe "kubectl get task sign-image-keyless -n ci -oyaml"
# p "audience: sigstore — Fulcio n'accepte que les tokens avec cette audience"
# p "expirationSeconds: 600 — le token est éphémère (10 minutes)"

# ============================================================================
# SECTION 4 — Exécution du pipeline
# ============================================================================

# p "  SECTION 4 — Exécution du pipeline"


# sleep 3
LATEST_PR=$(kubectl get pipelineruns -n ci --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

p "Workflow du pipeline keyless :"
cat <<'EOF'
  verify-source
    └─ git-clone
        └─ build-go-app
            └─ run-quality-checks
                └─ push-container-image
                    ├─ ** sign-image-keyless
                    ├─ create-source-vsa
                    ├─ scan-image
                    └─ notify-release
EOF


p "Suivi des logs de la tâche sign-image-keyless..."
if command -v tkn &>/dev/null; then
    pei "tkn pr logs -f ${LATEST_PR} -n ci -t sign-image-keyless"
else
    p "tkn non disponible — attente de la fin du pipeline..."
    kubectl wait --for=condition=Succeeded pipelinerun/${LATEST_PR} -n ci --timeout=600s 2>/dev/null || true
fi

# pe "kubectl get pipelinerun ${LATEST_PR} -n ci -o jsonpath='{.status.conditions[0].reason}' && echo"

# ============================================================================
# SECTION 5 — Vérification de la signature keyless
# ============================================================================

p "  Vérification de la signature keyless"
# p "Contrairement à la vérification par clé, le keyless utilise l'identité certificat + l'émetteur OIDC"
p "D'abord, initialiser la racine TUF de cosign pour faire confiance au CA Fulcio et à la clé Rekor locaux"
ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')
TUF_ROOT_FILE=$(mktemp)
pe "kubectl get configmap sigstore-tuf-root -n ci -o jsonpath='{.data.root\.json}' > ${TUF_ROOT_FILE}"
pe "cosign initialize --mirror=${TUF_MIRROR_LOCAL} --root=${TUF_ROOT_FILE}"

pe "cosign verify \
  --certificate-identity=https://kubernetes.io/namespaces/ci/serviceaccounts/pipeline-keyless-signer \
  --certificate-oidc-issuer=${ISSUER} \
  --rekor-url=${REKOR_URL_LOCAL} \
  --insecure-ignore-sct \
  --registry-cacert=${REGISTRY_CA} \
  ${IMAGE_REF} 2>&1 | head -20"

# p "La signature est valide !"
# p "  - Aucune clé privée nécessaire pour la vérification"
# p "  - L'identité est liée au ServiceAccount via OIDC"
# p "  - L'événement de signature est enregistré dans Rekor (auditable)"

# # ============================================================================
# # SECTION 6 — Provenance SLSA (Tekton Chains, keyless via Fulcio)
# # ============================================================================

# p "  SECTION 6 — Provenance SLSA (Tekton Chains, keyless via Fulcio)"
# p "Tekton Chains signe également via Fulcio — même instance Sigstore locale"

# CHAINS_IDENTITY="https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller"

# p "Attente de la signature par Chains..."
# for i in $(seq 1 12); do
#     SIGNED=$(kubectl get pipelinerun ${LATEST_PR} -n ci -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null)
#     [ "$SIGNED" = "true" ] && break
#     sleep 5
# done

# if [ "$SIGNED" = "true" ]; then
#     pe "cosign verify-attestation \
#   --certificate-identity=${CHAINS_IDENTITY} \
#   --certificate-oidc-issuer=${ISSUER} \
#   --rekor-url=${REKOR_URL_LOCAL} \
#   --insecure-ignore-sct \
#   --type slsaprovenance \
#   --registry-cacert=${REGISTRY_CA} \
#   ${IMAGE_REF} 2>&1 | head -5"
#     p "La provenance SLSA est valide — signée par Tekton Chains via Fulcio (keyless)"
# else
#     p "Chains n'a pas encore signé — vérification de la provenance ignorée"
# fi
p "TODO: Accepter la PR sur le Gitea de Prod"
p "✅"
