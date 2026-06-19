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
export SSL_CERT_FILE="${CA_CERT}"
CI_CONTEXT="kind-ci-cluster"
CHALLENGE3_SECURITY="${SCRIPT_DIR}/../challenge3/security"

source "${SCRIPT_DIR}/../../setup/scripts/check-sigstore.sh"
check_tuf_root

WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# --- Resolve IMAGE_DIGEST from the latest successful PipelineRun ---
LATEST_PR_NAME=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n ci \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
IMAGE_DIGEST=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${LATEST_PR_NAME} -n ci \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)

if [ -z "${IMAGE_DIGEST}" ]; then
    echo "ERROR: Could not resolve IMAGE_DIGEST from PipelineRun ${LATEST_PR_NAME}."
    echo "  Run a build pipeline first (e.g. make trigger-challenge3-build-secure)"
    exit 1
fi

OIDC_ISSUER=$(kubectl --context ${CI_CONTEXT} get --raw /.well-known/openid-configuration | jq -r '.issuer')

# --- Initialize local TUF root for Sigstore verification ---
TUF_ROOT_FILE=$(mktemp)
kubectl --context ${CI_CONTEXT} get configmap sigstore-tuf-root -n ci \
  -o jsonpath='{.data.root\.json}' > "${TUF_ROOT_FILE}"
cosign initialize --mirror=http://${TUF_HOST} --root=${TUF_ROOT_FILE}
rm -f "${TUF_ROOT_FILE}"

p "=== DEMO : Vérification post-pipeline avec Conforma et Ampel ==="
p "  Image : ${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST}"
p "  PipelineRun : ${LATEST_PR_NAME}"



p "1. Explorer la politique Conforma (Rego)"
pe "bat ${CHALLENGE3_SECURITY}/conforma-policies/sbom-baseline-check.rego"

# p "  Cette politique Rego définit 3 règles :"
# p "    deny  sbom_attached             — un SBOM doit être attaché à l'image (OCI referrer)"
# p "    deny  sbom_packages_match_baseline — les paquets du SBOM doivent correspondre à la baseline"
# p "    warn  sbom_no_missing_packages  — alerte si des paquets attendus sont absents"
# p "  En cas de deny → Conforma échoue, l'image est non conforme"
# p "  En cas de warn → Conforma réussit, mais signale des dérives"

p "2. Charger la baseline SBOM depuis le ConfigMap (données fraîches à chaque exécution)"
CONFORMA_POLICY_DIR="${WORK_DIR}/conforma-policies"
cp -r "${CHALLENGE3_SECURITY}/conforma-policies" "${CONFORMA_POLICY_DIR}"
pe "kubectl --context ${CI_CONTEXT} get configmap golang-baseline-sbom -n ci \
  -o jsonpath='{.data.baseline-packages\.json}' \
  > ${CONFORMA_POLICY_DIR}/baseline_packages.json"
pe "bat ${CONFORMA_POLICY_DIR}/baseline_packages.json | jq '.[0:5]'"
p "  OPA charge les fichiers .json du répertoire de politique dans data.*"
p "  baseline_packages.json → data.baseline_packages (utilisé par le Rego)"

if command -v ec &>/dev/null; then
    p "3. Exécuter Conforma (ec validate image)"
    pe "ec validate image \
  --images '{\"components\":[{\"name\":\"recipe-api\",\"containerImage\":\"${REGISTRY_HOST}/recipe-api:v3.0@${IMAGE_DIGEST}\"}]}' \
  --policy '{\"sources\":[{\"name\":\"sbom-baseline\",\"policy\":[\"${CONFORMA_POLICY_DIR}/\"]}]}' \
  --certificate-identity-regexp 'https://kubernetes.io/namespaces/(ci|tekton-chains)/serviceaccounts/(pipeline-keyless-signer|tekton-chains-controller)' \
  --certificate-oidc-issuer ${OIDC_ISSUER} \
  --rekor-url http://${REKOR_HOST} \
  --extra-rule-data '\"allowed_registry_prefixes=[\"\"registry.registry.svc.cluster.local:5000\"\"]\"' \
  --output text 2>&1 || true"
else
    p "3. Conforma (ec) non installé — installer avec : make install-conforma"
fi

p "4. Explorer la politique Ampel (HJSON)"
pe "bat ${CHALLENGE3_SECURITY}/ampel-policies/verify-build-artifacts.hjson"

# p "  Cette politique Ampel définit 2 blocs de vérification :"
# p "    sbom-check              — vérifie qu'une attestation SBOM existe pour l'image"
# p "                              (politique externe : carabiner-dev/policies#sbom/sbom-exists.json)"
# p "    slsa-provenance-check   — vérifie l'identité du builder dans la provenance SLSA"
# p "                              (politique externe : carabiner-dev/policies#slsa/slsa-builder-id.json)"
# p "                              Contrôle mappé : SLSA BUILD LEVEL_3"
# p "  Le builderId attendu est passé via --context lors de l'invocation"

if command -v ampel &>/dev/null; then
    p "5. Exécuter Ampel verify"
    # p "  Vérifie que l'image possède :"
    # p "    - Une attestation SBOM (in-toto, poussée par cosign attest)"
    # p "    - Une provenance SLSA avec le bon builder ID (Tekton Chains)"

    pe "ampel verify \
  ${IMAGE_DIGEST} \
  --policy ${CHALLENGE3_SECURITY}/ampel-policies/verify-build-artifacts.hjson \
  --collector \"coci:${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST}\" \
  --context \"builderId:https://tekton.dev/chains/v2\" \
  --format tty 2>&1 || true"

    p "  Note : L'option --signer est omise car Ampel v1.2.1 ne supporte pas"
    p "  les racines Sigstore personnalisées (Fulcio/TUF local). La bibliothèque"
    p "  signer le permet via WithSigstoreRootsPath, mais le CLI ne l'expose pas."
    p "  Les signatures sont vérifiables directement avec cosign :"

  #   pe "cosign verify-attestation \
  # --certificate-identity=https://kubernetes.io/namespaces/ci/serviceaccounts/pipeline-keyless-signer \
  # --certificate-oidc-issuer=${OIDC_ISSUER} \
  # --rekor-url=http://${REKOR_HOST} \
  # --insecure-ignore-sct \
  # --type spdxjson \
  # --registry-cacert=${CA_CERT} \
  # ${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST} 2>&1 | head -5 || true"

  #   p "  Quand Ampel supportera --sigstore-roots, la vérification complète sera :"
  #   p "    --signer 'sigstore:::${OIDC_ISSUER}:::https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller'"
  #   p "    --signer 'sigstore:::${OIDC_ISSUER}:::https://kubernetes.io/namespaces/ci/serviceaccounts/pipeline-keyless-signer'"
else
    p "5. Ampel non installé — installer avec : make install-ampel"
fi

p "✅"
