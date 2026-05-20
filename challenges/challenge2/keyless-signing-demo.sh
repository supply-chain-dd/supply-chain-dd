#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COSIGN_PUB="${REPO_ROOT}/cosign.pub"
REGISTRY_CA="${REPO_ROOT}/setup/certs/registry.crt"
REGISTRY_URL="localhost:30000"
IMAGE_NAME="recipe-api"
IMAGE_TAG="v2.0-keyless"
IMAGE_REF="${REGISTRY_URL}/${IMAGE_NAME}:${IMAGE_TAG}"
REKOR_NODE_PORT="${REKOR_NODE_PORT:-30006}"
TUF_NODE_PORT="${TUF_NODE_PORT:-30007}"

if ! command -v cosign &>/dev/null; then
    echo "cosign not installed. See: https://docs.sigstore.dev/cosign/installation/"
    exit 1
fi

if ! command -v tkn &>/dev/null; then
    echo "tkn CLI not found. Install with: make -C ${REPO_ROOT} install-tkn"
    echo "   Pipeline logs will not be shown in real time."
fi

# --- Sigstore service URLs via NodePort ---
REKOR_URL_LOCAL="http://localhost:${REKOR_NODE_PORT}"
TUF_MIRROR_LOCAL="http://localhost:${TUF_NODE_PORT}"

cleanup() {
    [ -n "${TUF_ROOT_FILE:-}" ] && rm -f "${TUF_ROOT_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

p "=== Keyless Image Signing — Cosign + Local Fulcio/Rekor ==="
# p "Instead of Tekton Chains signing images with a static cosign keypair,"
# p "this pipeline signs images in-pipeline using keyless signing:"
# p "  - A projected ServiceAccount token serves as OIDC identity"
# p "  - Local Fulcio issues a short-lived certificate"
# p "  - The signature is logged in local Rekor (transparency log)"
# p "  - No private keys to manage!"

# ============================================================================
# SECTION 1 — Local Sigstore Stack
# ============================================================================

# p "  SECTION 1 — Local Sigstore Stack"
# p "The sigstore/scaffolding Helm chart deploys Fulcio, Rekor, CT log, and TUF"

pe "kubectl get pods -n fulcio-system"
p "Fulcio is the Certificate Authority — issues short-lived signing certificates"

pe "kubectl get pods -n rekor-system"
p "Rekor is the transparency log — records all signing events immutably"

pe "kubectl get pods -n tuf-system"
p "TUF distributes the root of trust for verifying Fulcio/Rekor"

# ============================================================================
# SECTION 2 — OIDC Identity
# ============================================================================

# p "  SECTION 2 — OIDC Identity for Signing"
p "The pipeline uses a dedicated ServiceAccount: pipeline-keyless-signer"

pe "kubectl get serviceaccount pipeline-keyless-signer -n ctf-challenge -o yaml | head -20"

p "The cluster's OIDC issuer is used by Fulcio to verify the SA token:"
pe "kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer'"

ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')

# p "Certificate identity for verification:"
# p "  https://kubernetes.io/namespaces/ctf-challenge/serviceaccounts/pipeline-keyless-signer"
# p "  OIDC issuer: ${ISSUER}"

# ============================================================================
# SECTION 3 — Projected ServiceAccount Token
# ============================================================================

p "  SECTION 3 — Projected ServiceAccount Token"
p "The sign-image-keyless task mounts a projected SA token as an OIDC identity:"

# pe "kubectl get task sign-image-keyless -n ctf-challenge -o jsonpath='{.spec.volumes}' | jq '.[0]'"
pe "kubectl get task sign-image-keyless -n ctf-challenge -oyaml"
p "audience: sigstore — Fulcio only accepts tokens with this audience"
p "expirationSeconds: 600 — token is short-lived (10 minutes)"

# ============================================================================
# SECTION 4 — Pipeline Execution
# ============================================================================

p "  SECTION 4 — Pipeline Execution"
p "Triggering the keyless signing pipeline..."

pe "kubectl create -f ${SCRIPT_DIR}/tekton/manual-pipelinerun-keyless.yaml"

sleep 3
LATEST_PR=$(kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

p "Following logs..."
if command -v tkn &>/dev/null; then
    pei "tkn pr logs -f ${LATEST_PR} -n ctf-challenge"
else
    p "tkn not available — waiting for pipeline to complete..."
    kubectl wait --for=condition=Succeeded pipelinerun/${LATEST_PR} -n ctf-challenge --timeout=600s 2>/dev/null || true
fi

pe "kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.status.conditions[0].reason}' && echo"

# ============================================================================
# SECTION 5 — Verify Keyless Signature
# ============================================================================

p "  SECTION 5 — Verifying the Keyless Signature"
p "Unlike key-based verification, keyless uses certificate identity + OIDC issuer"
p "First, initialize cosign's TUF root to trust the local Fulcio CA and Rekor key"

TUF_ROOT_FILE=$(mktemp)
kubectl get configmap sigstore-tuf-root -n ctf-challenge -o jsonpath='{.data.root\.json}' > "${TUF_ROOT_FILE}"
pe "cosign initialize --mirror=${TUF_MIRROR_LOCAL} --root=${TUF_ROOT_FILE}"

pe "cosign verify \
  --certificate-identity=https://kubernetes.io/namespaces/ctf-challenge/serviceaccounts/pipeline-keyless-signer \
  --certificate-oidc-issuer=${ISSUER} \
  --rekor-url=${REKOR_URL_LOCAL} \
  --insecure-ignore-sct \
  --registry-cacert=${REGISTRY_CA} \
  ${IMAGE_REF} 2>&1 | head -20"

p "The signature is valid!"
p "  - No private key needed for verification"
p "  - Identity is bound to the ServiceAccount via OIDC"
p "  - The signing event is recorded in Rekor (auditable)"

# ============================================================================
# SECTION 6 — SLSA Provenance (still from Tekton Chains)
# ============================================================================

p "  SECTION 6 — SLSA Provenance (Tekton Chains)"
p "Tekton Chains still generates SLSA provenance (key-based signing)"

p "Waiting for Chains to sign..."
for i in $(seq 1 12); do
    SIGNED=$(kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null)
    [ "$SIGNED" = "true" ] && break
    sleep 5
done

if [ "$SIGNED" = "true" ]; then
    pe "cosign verify-attestation --insecure-ignore-tlog --key ${COSIGN_PUB} --type slsaprovenance --registry-cacert=${REGISTRY_CA} ${IMAGE_REF} 2>&1 | head -5"
    p "SLSA provenance is valid and signed by Tekton Chains"
else
    p "Chains has not signed yet — provenance verification skipped"
fi

# ============================================================================
# SECTION 7 — Comparison
# ============================================================================

# p "  SECTION 7 — Key-based vs Keyless Signing"
# p ""
# p "  Key-based (Tekton Chains):            Keyless (in-pipeline):"
# p "  ──────────────────────────            ─────────────────────"
# p "  cosign keypair in K8s Secret          No keys to manage"
# p "  Chains controller signs async         cosign signs in-pipeline"
# p "  Verify with: cosign.pub               Verify with: SA identity + OIDC issuer"
# p "  Key rotation is manual                Certificates are ephemeral (10 min)"
# p "  No transparency log                   All events in Rekor"
# p ""
# p "Both approaches coexist in this setup:"
# p "  make trigger-challenge2-build-with-chains  — key-based (Chains)"
# p "  make trigger-challenge2-build-keyless      — keyless (Fulcio)"

p ""
