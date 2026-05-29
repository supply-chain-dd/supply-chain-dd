#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd ../.. && pwd)"
CI_CONTEXT="kind-ctf-cluster"
PROD_CONTEXT="kind-ctf-production-cluster"
GITEA_URL="http://localhost:30002"
PROD_GITEA_URL="http://localhost:30004"
GITEA_USER="ctf-admin"
GITEA_PASS="CTFSecurePass123!"

WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# Prérequis
if ! kubectl --context ${CI_CONTEXT} cluster-info &>/dev/null; then
    echo "❌ Le cluster CI (${CI_CONTEXT}) n'est pas accessible."
    exit 1
fi
if ! kubectl --context ${PROD_CONTEXT} cluster-info &>/dev/null; then
    echo "❌ Le cluster de production (${PROD_CONTEXT}) n'est pas accessible."
    exit 1
fi

p "=== DEMO : Workflow CI/CD de bout en bout — Du code source à la production ==="

# ============================================================================
# PHASE 0 — État initial
# ============================================================================

p "  PHASE 0 — État initial de la production"

p "1. Interface ArgoCD : http://localhost:30080"
p "→ Ouvrez l'interface ArgoCD pour suivre le déploiement en temps réel"

p "2. Vérifier que l'API de production est fonctionnelle"
pe "curl -s http://localhost:30081/recipes | jq ."

# ============================================================================
# PHASE 1 — Modification du code source
# ============================================================================

p "  PHASE 1 — Modification du code source"

p "3. Cloner le dépôt recipe-api depuis Gitea"

# Git config pour éviter les problèmes d'identité
cat > ${WORK_DIR}/.gitconfig <<EOF
[user]
    name = CTF Admin
    email = ctf-admin@ctf.local
[credential]
    helper = store
EOF
echo "http://${GITEA_USER}:${GITEA_PASS}@localhost:30002" > ${WORK_DIR}/.git-credentials

pe "GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git clone ${GITEA_URL}/${GITEA_USER}/recipe-api.git ${WORK_DIR}/recipe-api"

p "4. Modifier le code — ajouter un commentaire pour déclencher un nouveau build"
cd ${WORK_DIR}/recipe-api

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
pe "echo '// build: ${TIMESTAMP}' >> main.go"
pe "tail -3 main.go"

BEFORE_PR_COUNT=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n ctf-challenge --no-headers 2>/dev/null | wc -l)

p "5. Commit et push vers main"
GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git add .
pe "GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git commit -m 'feat: bump version to v2.0-${TIMESTAMP}'"

p "git push origin main"
GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git push origin main 2>&1

cd "${SCRIPT_DIR}"

# ============================================================================
# PHASE 2 — Pipeline de build
# ============================================================================

p "  PHASE 2 — Pipeline de build déclenchée par le webhook"

p "→ Le push sur main déclenche le webhook Gitea → EventListener → PipelineRun"

p "6. Attente du déclenchement de la pipeline de build..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_COUNT=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n ctf-challenge --no-headers 2>/dev/null | wc -l)
    if [ "$CURRENT_COUNT" -gt "$BEFORE_PR_COUNT" ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$CURRENT_COUNT" -gt "$BEFORE_PR_COUNT" ]; then
    pe "kubectl --context ${CI_CONTEXT} get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp"
    p "→ Pipeline déclenchée automatiquement par le webhook"
else
    p "⚠ Le webhook n'a pas déclenché de PipelineRun — déclenchement manuel"
    pe "kubectl --context ${CI_CONTEXT} create -f ${SCRIPT_DIR}/../challenge2/tekton/manual-pipelinerun.yaml"
    sleep 3
fi

BUILD_PR_NAME=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n ctf-challenge \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

p "7. Suivi des logs de la pipeline de build"
pe "tkn pr logs -f ${BUILD_PR_NAME} -n ctf-challenge --context ${CI_CONTEXT}"

pe "kubectl --context ${CI_CONTEXT} get pipelinerun ${BUILD_PR_NAME} -n ctf-challenge \
  -o jsonpath='{.status.conditions[0].reason}' && echo"

# ============================================================================
# PHASE 3 — Pipeline de release
# ============================================================================

p "  PHASE 3 — Pipeline de release"

p "→ La tâche notify-release a envoyé un webhook à l'EventListener de release"

p "8. Vérification du déclenchement de la pipeline de release"
TIMEOUT=30
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    RELEASE_COUNT=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n release-pipeline --no-headers 2>/dev/null | wc -l)
    if [ "$RELEASE_COUNT" -gt 0 ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$RELEASE_COUNT" -gt 0 ]; then
    pe "kubectl --context ${CI_CONTEXT} get pipelineruns -n release-pipeline"
    RELEASE_PR_NAME=$(kubectl --context ${CI_CONTEXT} get pipelineruns -n release-pipeline \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

    p "9. Suivi des logs de la pipeline de release"
    pe "tkn pr logs -f ${RELEASE_PR_NAME} -n release-pipeline --context ${CI_CONTEXT}"
else
    p "⚠ La pipeline de release n'a pas été déclenchée automatiquement"
    p "→ Vérifiez que l'EventListener est déployé : kubectl get eventlistener -n release-pipeline"
fi

# ============================================================================
# PHASE 4 — Revue et merge de la PR
# ============================================================================

p "  PHASE 4 — Revue et merge de la PR de release"

p "10. Lister les PR ouvertes dans production-manifests"
pe "curl -s -u ${GITEA_USER}:${GITEA_PASS} \
  ${PROD_GITEA_URL}/api/v1/repos/ctf-admin/production-manifests/pulls?state=open | jq '.[].title'"

PR_NUMBER=$(curl -s -u ${GITEA_USER}:${GITEA_PASS} \
  ${PROD_GITEA_URL}/api/v1/repos/ctf-admin/production-manifests/pulls?state=open \
  | jq -r '.[0].number // empty' 2>/dev/null)

if [ -n "$PR_NUMBER" ]; then
    p "11. Contenu de la PR #${PR_NUMBER}"
    pe "curl -s -u ${GITEA_USER}:${GITEA_PASS} \
  ${PROD_GITEA_URL}/api/v1/repos/ctf-admin/production-manifests/pulls/${PR_NUMBER} \
  | jq '{title: .title, body: .body, head: .head.label, base: .base.label}'"

    p "12. Merger la PR"
    pe "curl -s -X POST -u ${GITEA_USER}:${GITEA_PASS} \
  -H 'Content-Type: application/json' \
  -d '{\"Do\": \"merge\"}' \
  ${PROD_GITEA_URL}/api/v1/repos/ctf-admin/production-manifests/pulls/${PR_NUMBER}/merge \
  | jq '.sha // .message'"

    p "→ PR mergée — le manifeste de production est mis à jour avec le nouveau digest"
else
    p "⚠ Aucune PR ouverte trouvée dans production-manifests"
fi

# ============================================================================
# PHASE 5 — Déploiement ArgoCD
# ============================================================================

p "  PHASE 5 — Déploiement ArgoCD"

p "→ ArgoCD détecte le changement dans le dépôt Git et synchronise"

p "13. Attente de la synchronisation ArgoCD..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    SYNC_STATUS=$(kubectl --context ${PROD_CONTEXT} get application recipe-api-production -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null)
    HEALTH=$(kubectl --context ${PROD_CONTEXT} get application recipe-api-production -n argocd \
      -o jsonpath='{.status.health.status}' 2>/dev/null)
    if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

pe "kubectl --context ${PROD_CONTEXT} get application recipe-api-production -n argocd \
  -o jsonpath='{\"Sync: \"}{.status.sync.status}{\"  Health: \"}{.status.health.status}' && echo"

p "→ Vérifiez dans l'interface ArgoCD : https://localhost:30443"

p "14. Vérifier que la nouvelle version est accessible"
pe "curl -s http://localhost:30081/recipes | jq ."

p "→ Le workflow complet : code source → build → release → PR → merge → ArgoCD → production"

p "✅"
