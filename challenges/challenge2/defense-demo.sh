#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITEA_URL="http://localhost:30002"
GITEA_USER="ctf-admin"
GITEA_PASS="CTFSecurePass123!"
REGISTRY_URL="https://localhost:30000"
REGISTRY_USER="ctf-admin"
REGISTRY_PASS="CTFRegistryPass123!"

kubectl scale deployment tekton-chains-controller --replicas=0 -n tekton-chains

# Setup: deploy secure pipeline + patch trigger template to point to it
p "0. Patch des pipelines avant de commiter"

pei "kubectl apply -f ${SCRIPT_DIR}/tekton-patched/pipelines/push-build-pipeline-secure.yaml"
pei "kubectl patch triggertemplate push-build-template -n ctf-challenge --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/resourcetemplates/0/spec/pipelineRef/name\",\"value\":\"push-build-pipeline-secure\"},{\"op\":\"replace\",\"path\":\"/spec/params/6/default\",\"value\":\"v2.0\"}]' 2>/dev/null || true"

WORK_DIR=$(mktemp -d)


p "1. Cloner le dépôt depuis Gitea"

echo "[user]" > ${WORK_DIR}/.gitconfig
echo "	name = CTF Admin" >> ${WORK_DIR}/.gitconfig
echo "	email = ctf-admin@localhost" >> ${WORK_DIR}/.gitconfig
echo "[credential]" >> ${WORK_DIR}/.gitconfig
echo "	helper = store --file ${WORK_DIR}/.git-credentials" >> ${WORK_DIR}/.gitconfig
echo "http://ctf-admin:CTFSecurePass123\!@localhost:30002" > ${WORK_DIR}/.git-credentials
chmod 600 ${WORK_DIR}/.git-credentials
pe "git clone ${GITEA_URL}/${GITEA_USER}/recipe-api.git ${WORK_DIR}/recipe-api"

cd "${WORK_DIR}/recipe-api"
p "=== DEMO DÉFENSE : Challenge 2 — Fuite de secrets dans les couches d'image ==="

# ============================================================================
# PHASE 1 — Corriger le code source
# ============================================================================


p "  PHASE 1 — Analyser et corriger le code source"




p "2. Le Dockerfile actuel est vulnérable (COPY . . + rm -rf .git)"
pe "cat Dockerfile"


p "3. Politique Rego custom pour détecter le pattern dangereux"
p "→ Seul un scan de misconfiguration du Dockerfile peut détecter le pattern dangereux"
pe "cat ${SCRIPT_DIR}/trivy-policies/copy_git_leak.rego"

p ""
p "4. Exécuter le scan de misconfiguration sur le Dockerfile vulnérable"
pe "trivy config --config-check ${SCRIPT_DIR}/trivy-policies/ --namespaces user Dockerfile"


p "5. Remplacer par un Dockerfile multi-stage"
cp "${SCRIPT_DIR}/tekton-patched/Dockerfile" Dockerfile
pe "cat Dockerfile"
# p "→ Stage builder : compile le binaire. Stage runtime : copie uniquement le binaire."


p "6. Ajouter un .dockerignore allowlist"
cp "${SCRIPT_DIR}/tekton-patched/.dockerignore" .dockerignore
pe "cat .dockerignore"


p "7. Résumé des modifications"
pe "git status"


p "8. Commit et push"
pe "git add Dockerfile .dockerignore"
pe "git commit -m 'fix: multi-stage build + .dockerignore'"

# Record PipelineRun count before push (to detect webhook trigger)
BEFORE_PR_COUNT=$(kubectl get pipelineruns -n ctf-challenge --no-headers 2>/dev/null | wc -l)

p "git push origin main"
git remote set-url origin "http://${GITEA_USER}:CTFSecurePass123%21@localhost:30002/${GITEA_USER}/recipe-api.git"
git push origin main

p "⚠  Pousser directement sur main est une pratique dangereuse en production."
p "→ Les changements doivent passer par une Pull Request avec review obligatoire."


p "9. Protéger la branche main via l'API Gitea"
pe "curl -s -X POST '${GITEA_URL}/api/v1/repos/${GITEA_USER}/recipe-api/branch_protections' \
  -u '${GITEA_USER}:${GITEA_PASS}' \
  -H 'Content-Type: application/json' \
  -d '{\"branch_name\":\"main\",\"enable_push\":false,\"required_approvals\":1}' | python3 -m json.tool 2>/dev/null || echo 'Protection configurée'"

cd "${SCRIPT_DIR}"

# ============================================================================
# PHASE 2 — Scanner et purger l'ancienne image
# ============================================================================


p "  PHASE 2 — Limites des scanners et purge de l'ancienne image"

p ""
p "1. Trivy image --scanners secret sur l'image vulnérable"
p "→ Trivy fusionne les couches (union filesystem) — le whiteout de rm -rf .git masque .git"
pe "trivy image --scanners secret --insecure localhost:30000/recipe-api:v1.0"
p "→ 0 secrets détectés — Trivy ne voit pas les secrets supprimés dans les couches supérieures"

p ""
p "2. Récupérer le digest et supprimer l'image vulnérable"
pe "DIGEST=\$(skopeo inspect docker://localhost:30000/recipe-api:v1.0 | jq -r .Digest)"
pe "echo \"Digest: \${DIGEST}\""

pe "curl -k -s -o /dev/null -w 'HTTP %{http_code}\n' -u ${REGISTRY_USER}:${REGISTRY_PASS} \
  -X DELETE ${REGISTRY_URL}/v2/recipe-api/manifests/\${DIGEST}"

pe "curl -k -s -u ${REGISTRY_USER}:${REGISTRY_PASS} ${REGISTRY_URL}/v2/recipe-api/tags/list"

# ============================================================================
# PHASE 3 — Pipeline déclenchée par le webhook
# ============================================================================


p "  PHASE 3 — Pipeline déclenchée par le webhook"

p "Le push sur main déclenche le webhook Gitea → EventListener → PipelineRun"

sleep 10
AFTER_PR_COUNT=$(kubectl get pipelineruns -n ctf-challenge --no-headers 2>/dev/null | wc -l)

if [ "$AFTER_PR_COUNT" -gt "$BEFORE_PR_COUNT" ]; then
    pe "kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp"
    p "→ Pipeline déclenchée automatiquement par le webhook"
    LATEST_PR_NAME=$(kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    pe "tkn pr logs -f ${LATEST_PR_NAME} -n ctf-challenge"
else
    p "⚠  Le webhook n'a pas déclenché de PipelineRun — déclenchement manuel"
    pe "kubectl create -f ${SCRIPT_DIR}/tekton-patched/manual-pipelinerun-secure.yaml"
    sleep 3
    LATEST_PR_NAME=$(kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    pe "tkn pr logs -f ${LATEST_PR_NAME} -n ctf-challenge"
fi

pe "kubectl get pipelineruns -n ctf-challenge"

# ============================================================================
# PHASE 4 — Vérification
# ============================================================================


p "  PHASE 4 — Vérification de la nouvelle image v2.0"


# p "1. L'image v2.0 est dans le registre"
pe "curl -k -s -u ${REGISTRY_USER}:${REGISTRY_PASS} ${REGISTRY_URL}/v2/recipe-api/tags/list"
# pe "oras discover localhost:30000/recipe-api:v2.0 \
#   --registry-config ~/.docker/config.json \
#   --ca-file ${SCRIPT_DIR}/../../setup/certs/registry.crt"
pe "SSL_CERT_FILE=/etc/containers/certs.d/localhost:30000/ca.crt \
  oras discover --plain-http=false \
  localhost:30000/recipe-api:v2.0 \
  --registry-config ~/.docker/config.json"
# p "2. Scan de secrets sur la nouvelle image"
# pe "trivy image --scanners secret --insecure localhost:30000/recipe-api:v2.0"
# p "→ 0 secrets — le multi-stage build ne copie que le binaire dans l'image finale"


# p "3. Scan de misconfiguration avec la politique Rego custom"
# pe "trivy image --scanners misconfig --config-check ${SCRIPT_DIR}/trivy-policies/ --namespaces user --insecure localhost:30000/recipe-api:v2.0"
# p "→ Aucune alerte — le Dockerfile n'est pas dans l'image (exclu par .dockerignore + multi-stage)"

# ============================================================================
# Résumé
# ============================================================================

rm -rf "${WORK_DIR}"


# p "=== RÉSUMÉ ==="
# p "1. Dockerfile multi-stage : seul le binaire dans l'image finale"
# p "2. .dockerignore allowlist : .git et .env exclus du contexte de build"
# p "3. Ancienne image vulnérable purgée du registre"
# p "4. Pipeline sécurisée avec vérification de source, scan et attestation"
# p "5. Branche main protégée via l'API Gitea"
# p "6. Nouvelle image vérifiée : aucun secret dans les couches"

p "✅"
