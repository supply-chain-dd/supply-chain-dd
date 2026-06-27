#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd ../.. && pwd)"
source "${SCRIPT_DIR}/../../setup/scripts/domains.sh"
REGISTRY_URL="https://${REGISTRY_HOST}"
REGISTRY_USER="sc-admin"
REGISTRY_PASS="RegistryPass123!"
CA_CERT="${SCRIPT_DIR}/../../setup/certs/registry.crt"
export SSL_CERT_FILE="${CA_CERT}"
CI_CONTEXT="kind-ci-cluster"
CHALLENGE3_SECURITY="${SCRIPT_DIR}/../challenge3/security"
PROD_GITEA_URL="http://${GITEA_PROD_HOST}"
GITEA_USER="sc-admin"
GITEA_PASS="SecurePass123!"

source "${SCRIPT_DIR}/../../setup/scripts/check-sigstore.sh"
check_tuf_root

WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# --- Initialize local TUF root for Sigstore verification ---
TUF_ROOT_FILE=$(mktemp)
kubectl --context ${CI_CONTEXT} get configmap sigstore-tuf-root -n ci \
  -o jsonpath='{.data.root\.json}' > "${TUF_ROOT_FILE}"
cosign initialize --mirror=http://${TUF_HOST} --root=${TUF_ROOT_FILE}
rm -f "${TUF_ROOT_FILE}"

OIDC_ISSUER=$(kubectl --context ${CI_CONTEXT} get --raw /.well-known/openid-configuration | jq -r '.issuer')

p "=== DEMO : Vérification post-pipeline avec Conforma et Ampel ==="

# ============================================================================
# PHASE 1 — Installer et déclencher la pipeline sécurisée (en arrière-plan)
# ============================================================================

p "1. Installer les pipelines avec portes de vérification"
pe "make -C ${PROJECT_ROOT} setup-release-pipeline-secure"

p "2. Lancer la pipeline de build sécurisée"
pe "make -C ${PROJECT_ROOT} trigger-build-with-release-gate"

sleep 3
BUILD_PR_NAME=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n ci \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

p "→ Pipeline de build déclenchée : ${BUILD_PR_NAME}"
p "  Pendant qu'elle s'exécute, explorons les outils de vérification..."

# ============================================================================
# PHASE 2 — Pendant que la pipeline tourne : explorer Conforma et Ampel
#            (sur la base de l'image de la DERNIÈRE pipeline réussie)
# ============================================================================

# --- Resolve IMAGE_DIGEST from the latest PREVIOUS successful PipelineRun ---
PREV_PR_NAMES=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n ci \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
PREV_PR_NAME=""
for pr in ${PREV_PR_NAMES}; do
    [ "${pr}" = "${BUILD_PR_NAME}" ] && continue
    PREV_PR_NAME="${pr}"
done
IMAGE_DIGEST=""
if [ -n "${PREV_PR_NAME}" ]; then
    IMAGE_DIGEST=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${PREV_PR_NAME} -n ci \
      -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)
fi

if [ -z "${IMAGE_DIGEST}" ]; then
    echo "WARN: Pas de pipeline précédente avec IMAGE_DIGEST — on attend la pipeline en cours..."
    TIMEOUT=300
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        IMAGE_DIGEST=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${BUILD_PR_NAME} -n ci \
          -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)
        [ -n "${IMAGE_DIGEST}" ] && break
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        echo "  attente de IMAGE_DIGEST... (${ELAPSED}s/${TIMEOUT}s)"
    done
    if [ -z "${IMAGE_DIGEST}" ]; then
        echo "ERROR: Could not resolve IMAGE_DIGEST."
        exit 1
    fi
fi

p "3. Explorer la politique Conforma (Rego)"
pe "bat ${CHALLENGE3_SECURITY}/conforma-policies/sbom-baseline-check.rego"

p "4. Charger la baseline SBOM depuis le ConfigMap (données fraîches à chaque exécution)"
CONFORMA_POLICY_DIR="${WORK_DIR}/conforma-policies"
cp -r "${CHALLENGE3_SECURITY}/conforma-policies" "${CONFORMA_POLICY_DIR}"
kubectl --context ${CI_CONTEXT} get configmap golang-baseline-sbom -n ci \
  -o jsonpath='{.data.baseline-packages\.json}' \
  > ${CONFORMA_POLICY_DIR}/baseline_packages.json
# pe "cat ${CONFORMA_POLICY_DIR}/baseline_packages.json | jq '.[0:5]'"
# p "  OPA charge les fichiers .json du répertoire de politique dans data.*"
# p "  baseline_packages.json → data.baseline_packages (utilisé par le Rego)"

if command -v ec &>/dev/null; then
    p "5. Exécuter Conforma (ec validate image)"
    pe "ec validate image \
  --images '{\"components\":[{\"name\":\"recipe-api\",\"containerImage\":\"${REGISTRY_HOST}/recipe-api:v3.0@${IMAGE_DIGEST}\"}]}' \
  --policy '{\"sources\":[{\"name\":\"sbom-baseline\",\"policy\":[\"${CONFORMA_POLICY_DIR}/\"]}]}' \
  --certificate-identity-regexp 'https://kubernetes.io/namespaces/(ci|tekton-chains)/serviceaccounts/(pipeline-keyless-signer|tekton-chains-controller)' \
  --certificate-oidc-issuer ${OIDC_ISSUER} \
  --rekor-url http://${REKOR_HOST} \
  --extra-rule-data '\"allowed_registry_prefixes=[\"\"registry.registry.svc.cluster.local:5000\"\"]\"' \
  --output text 2>&1 || true"
else
    p "5. Conforma (ec) non installé — installer avec : make install-conforma"
fi

p "6. Explorer la politique Ampel (HJSON)"
pe "bat ${CHALLENGE3_SECURITY}/ampel-policies/verify-build-artifacts.hjson"

# p "  Cette politique Ampel définit 2 blocs de vérification :"
# p "    sbom-check              — vérifie qu'une attestation SBOM existe pour l'image"
# p "                              (politique externe : carabiner-dev/policies#sbom/sbom-exists.json)"
# p "    slsa-provenance-check   — vérifie l'identité du builder dans la provenance SLSA"
# p "                              (politique externe : carabiner-dev/policies#slsa/slsa-builder-id.json)"
# p "                              Contrôle mappé : SLSA BUILD LEVEL_3"
# p "  Le builderId attendu est passé via --context lors de l'invocation"

if command -v ampel &>/dev/null; then
    p "7. Exécuter Ampel verify"
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
    p "7. Ampel non installé — installer avec : make install-ampel"
fi

# ============================================================================
# PHASE 3 — Revenir à la pipeline : logs et résultats
# ============================================================================

p "=== Retour à la pipeline de build déclenchée plus tôt ==="

p "8. Logs de la pipeline de build (${BUILD_PR_NAME})"
pe "tkn pr logs -f ${BUILD_PR_NAME} -n ci --context ${CI_CONTEXT}"

p "9. Statut de la pipeline de build"
pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${BUILD_PR_NAME} -n ci \
  -o jsonpath='{\"Status: \"}{.status.conditions[0].reason}' && echo"

p "10. Attendre le déclenchement automatique de la release pipeline sécurisée..."

TIMEOUT=120
ELAPSED=0
RELEASE_PR_NAME=""
RELEASE_AGE=""
BUILD_AGE=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${BUILD_PR_NAME} -n ci \
  -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
while [ $ELAPSED -lt $TIMEOUT ]; do
    RELEASE_PR_NAME=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n release-pipeline \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    if [ -n "${RELEASE_PR_NAME}" ]; then
        RELEASE_AGE=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
          -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
        if [[ "${RELEASE_AGE}" > "${BUILD_AGE}" ]]; then
            echo "→ Release pipeline déclenchée : ${RELEASE_PR_NAME}"
            break
        fi
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "  attente... (${ELAPSED}s/${TIMEOUT}s)"
done

if [ -z "${RELEASE_PR_NAME}" ] || [[ ! "${RELEASE_AGE}" > "${BUILD_AGE}" ]]; then
    p "⚠ Timeout : aucune release pipeline déclenchée dans les ${TIMEOUT}s"
    p "  Vérifier manuellement : kubectl get pipelineruns -n release-pipeline"
    p "✅"
    exit 0
fi

p "11. Logs de la release pipeline (${RELEASE_PR_NAME})"
pe "tkn pr logs -f ${RELEASE_PR_NAME} -n release-pipeline --context ${CI_CONTEXT}"

pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
  -o jsonpath='{\"Status: \"}{.status.conditions[0].reason}' && echo"

PIPELINE_STATUS=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
  -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)

if [ "${PIPELINE_STATUS}" = "Succeeded" ]; then
    p "12. Résultat de la vérification de politique"
    pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
  -o jsonpath='{.status.results}' | jq ."

    p "13. Vérifier la PR créée dans production-manifests"
    pe "curl -s -u ${GITEA_USER}:${GITEA_PASS} \
  ${PROD_GITEA_URL}/api/v1/repos/sc-admin/production-manifests/pulls?state=open \
  | jq '.[0] | {title: .title, body: .body}'"

    p "→ L'image a passé toutes les vérifications, a été promue, et une PR a été créée"
else
    p "→ La pipeline a échoué : l'image n'a pas été promue en production"
    pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
  -o jsonpath='{.status.conditions[0].message}' && echo"
fi

p "✅"
