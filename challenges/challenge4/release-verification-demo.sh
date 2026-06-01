#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd ../.. && pwd)"
source "${SCRIPT_DIR}/../../setup/scripts/domains.sh"
CI_CONTEXT="kind-ci-cluster"
PROD_GITEA_URL="http://${GITEA_PROD_HOST}"
GITEA_USER="sc-admin"
GITEA_PASS="SecurePass123!"

p "=== DEMO DÉFENSE : Challenge 4 — Pipeline de release sécurisée ==="
p "  Deux améliorations :"
p "    1. Pipeline de BUILD : notify-release dans un bloc finally, attend Tekton Chains"
p "    2. Pipeline de RELEASE : porte de vérification Conforma avant la promotion"

# ============================================================================
# PHASE 1 — Déployer les pipelines sécurisées
# ============================================================================

p "  PHASE 1 — Déployer les pipelines sécurisées"

p "1. Installer les pipelines avec portes de vérification"
pe "make -C ${PROJECT_ROOT} setup-release-pipeline-secure"

# ============================================================================
# PHASE 2 — Explorer les pipelines sécurisées
# ============================================================================

p "  PHASE 2 — Explorer les pipelines sécurisées"

p "2. Pipeline de build : le bloc finally et ses conditions"
pe "kubectl --context ${CI_CONTEXT} get pipeline push-build-pipeline-with-release-gate -n ci -o yaml | yq '.spec.finally'"

p "→ notify-release ne s'exécute que si sign-image-keyless, attest-sbom, scan-image et create-source-vsa ont réussi"

p "3. La tâche notify-release-verified : attente de Tekton Chains"
pe "kubectl --context ${CI_CONTEXT} get task notify-release-verified -n ci -o yaml | yq '.spec.steps'"

p "→ Étape 1 : interroge l'API Kubernetes pour chains.tekton.dev/signed=true sur le TaskRun push-container-image"
p "→ Étape 2 : envoie le webhook au EventListener de la release pipeline sécurisée"

p "4. Pipeline de release : la tâche verify-image-policy (Conforma)"
pe "kubectl --context ${CI_CONTEXT} get task verify-image-policy -n release-pipeline -o yaml | yq '.spec.steps'"

p "→ Télécharge cosign + ec CLI, initialise TUF, exécute ec validate image avec vérification keyless"
p "→ Si l'image n'a pas de signature, de provenance SLSA ou échoue aux politiques → pipeline bloquée"

# ============================================================================
# PHASE 3 — Déclencher la pipeline de build avec release gate
# ============================================================================

p "  PHASE 3 — Déclencher la pipeline de build (auto-trigger release)"

p "5. Lancer la pipeline de build avec le bloc finally"
pe "make -C ${PROJECT_ROOT} trigger-build-with-release-gate"

sleep 3
BUILD_PR_NAME=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n ci \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

p "6. Suivre les logs de la pipeline de build (${BUILD_PR_NAME})"
pe "tkn pr logs -f ${BUILD_PR_NAME} -n ci --context ${CI_CONTEXT}"

p "7. Vérifier le statut de la pipeline de build"
pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${BUILD_PR_NAME} -n ci \
  -o jsonpath='{\"Status: \"}{.status.conditions[0].reason}' && echo"

p "8. Attendre le déclenchement automatique de la release pipeline sécurisée..."

TIMEOUT=120
ELAPSED=0
RELEASE_PR_NAME=""
while [ $ELAPSED -lt $TIMEOUT ]; do
    RELEASE_PR_NAME=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n release-pipeline \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    if [ -n "${RELEASE_PR_NAME}" ]; then
        RELEASE_AGE=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
          -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
        BUILD_AGE=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${BUILD_PR_NAME} -n ci \
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

p "9. Suivre les logs de la release pipeline (${RELEASE_PR_NAME})"
pe "tkn pr logs -f ${RELEASE_PR_NAME} -n release-pipeline --context ${CI_CONTEXT}"

# ============================================================================
# PHASE 4 — Vérifier les résultats
# ============================================================================

p "  PHASE 4 — Vérifier les résultats"

pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
  -o jsonpath='{\"Status: \"}{.status.conditions[0].reason}' && echo"

PIPELINE_STATUS=$(kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
  -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)

if [ "${PIPELINE_STATUS}" = "Succeeded" ]; then
    p "10. Résultat de la vérification de politique"
    pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${RELEASE_PR_NAME} -n release-pipeline \
  -o jsonpath='{.status.results}' | jq ."

    p "11. Vérifier la PR créée dans production-manifests"
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
