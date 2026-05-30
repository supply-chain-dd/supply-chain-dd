#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../setup/scripts/domains.sh"
GITEA_URL="http://${GITEA_HOST}"
GITEA_USER="sc-admin"
GITEA_PASS="SecurePass123!"
REGISTRY_URL="https://${REGISTRY_HOST}"
REGISTRY_USER="sc-admin"
REGISTRY_PASS="RegistryPass123!"
CA_CERT="${SCRIPT_DIR}/../../setup/certs/registry.crt"

WORK_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

p "=== DEMO DÉFENSE : Challenge 3 — Empoisonnement d'image de base ==="
kubectl scale deployment tekton-chains-controller --replicas=1 -n tekton-chains

# ============================================================================
# PHASE 0 — Déployer la pipeline sécurisée
# ============================================================================

p "  PHASE 0 — Déployer la pipeline sécurisée et ses ressources"
pei "make -C ${SCRIPT_DIR}/../.. setup-challenge3-tekton-secure"

p "La pipeline sécurisée ajoute deux étapes :"
p "  - verify-base-image : vérifie registre, digest, SBOM et baseline de la build image AVANT le build"
p "  - generate-sbom : génère le SBOM de l'image construite APRÈS le push"

p "1. Générer la baseline SBOM à partir de l'image propre (Docker Hub) via un Job Kubernetes"
kubectl delete job generate-baseline-from-hub -n ci --ignore-not-found 2>/dev/null
pe "kubectl create -f ${SCRIPT_DIR}/tekton-patched/jobs/generate-baseline-from-hub-job.yaml"
kubectl wait --for=condition=ready pod -l job-name=generate-baseline-from-hub -n ci --timeout=120s 2>/dev/null
BASELINE_POD=$(kubectl get pods -n ci -l job-name=generate-baseline-from-hub -o jsonpath='{.items[0].metadata.name}')
pe "kubectl logs -f ${BASELINE_POD} -n ci"
kubectl logs ${BASELINE_POD} -n ci | sed -n '/^===BASELINE_JSON_START===/,/^===BASELINE_JSON_END===/{ //!p; }' > ${WORK_DIR}/baseline-packages.json
pe "cat ${WORK_DIR}/baseline-packages.json"
pe "kubectl create configmap golang-baseline-sbom \
  --namespace ci \
  --from-file=baseline-packages.json=${WORK_DIR}/baseline-packages.json \
  --dry-run=client -o yaml | kubectl apply -f -"
kubectl delete job generate-baseline-from-hub -n ci --ignore-not-found 2>/dev/null

# ============================================================================
# PHASE 1 — Exécuter la pipeline (devrait échouer)
# ============================================================================

p "  PHASE 1 — Exécuter la pipeline sécurisée (le Dockerfile actuel devrait échouer)"

p "2. Déclencher la pipeline manuellement"
pe "kubectl create -f ${SCRIPT_DIR}/tekton-patched/manual-pipelinerun-with-chains-secure.yaml"

sleep 5
LATEST_PR_NAME=$(kubectl get pipelineruns -n ci --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

p "3. Suivre les logs du pipeline (échec attendu à verify-base-image)"
pe "tkn pr logs -f ${LATEST_PR_NAME} -n ci"

pe "kubectl get pipelineruns -n ci"

p "La pipeline a échoué : le Dockerfile ne respecte pas les exigences de sécurité"

# ============================================================================
# PHASE 2 — Corriger : pousser les images propres et créer une PR
# ============================================================================

p "  PHASE 2 — Corriger : pousser les images propres et mettre à jour le Dockerfile"

p "4. Pousser les images propres depuis Docker Hub vers le registre local"
pe "podman pull golang:1.25-alpine"
pe "podman tag golang:1.25-alpine ${REGISTRY_HOST}/golang:1.25-alpine"
pe "podman push ${REGISTRY_HOST}/golang:1.25-alpine"

pe "podman pull alpine:3.20"
pe "podman tag alpine:3.20 ${REGISTRY_HOST}/alpine:3.20"
pe "podman push ${REGISTRY_HOST}/alpine:3.20"

p "Conseil : Activez les tags immuables sur votre registre si disponible"

p "5. Récupérer les digests des images propres"
pe "GOLANG_DIGEST=\$(skopeo inspect  docker://${REGISTRY_HOST}/golang:1.25-alpine | jq -r .Digest)"
pe "echo \"golang digest: \${GOLANG_DIGEST}\""

pe "ALPINE_DIGEST=\$(skopeo inspect  docker://${REGISTRY_HOST}/alpine:3.20 | jq -r .Digest)"
pe "echo \"alpine digest: \${ALPINE_DIGEST}\""

p "6. Générer les SBOMs, les attacher et créer la baseline via un Job dans le cluster"
kubectl delete job generate-sbom-baseline -n ci --ignore-not-found 2>/dev/null
pe "kubectl create -f ${SCRIPT_DIR}/tekton-patched/jobs/generate-sbom-baseline-job.yaml"
kubectl wait --for=condition=ready pod -l job-name=generate-sbom-baseline -n ci --timeout=300s 2>/dev/null
BASELINE_POD=$(kubectl get pods -n ci -l job-name=generate-sbom-baseline -o jsonpath='{.items[0].metadata.name}')
pe "kubectl logs -f ${BASELINE_POD} -n ci"

p "7. Créer la baseline ConfigMap à partir du SBOM généré dans le cluster"
kubectl logs ${BASELINE_POD} -n ci | sed -n '/^===BASELINE_JSON_START===/,/^===BASELINE_JSON_END===/{ //!p; }' > ${WORK_DIR}/baseline-packages.json
pe "cat ${WORK_DIR}/baseline-packages.json"
pe "kubectl create configmap golang-baseline-sbom \
  --namespace ci \
  --from-file=baseline-packages.json=${WORK_DIR}/baseline-packages.json \
  --dry-run=client -o yaml | kubectl apply -f -"
kubectl delete job generate-sbom-baseline -n ci --ignore-not-found 2>/dev/null

# --- Git setup ---
echo "[user]" > ${WORK_DIR}/.gitconfig
echo "	name = SC Admin" >> ${WORK_DIR}/.gitconfig
echo "	email = sc-admin@localhost" >> ${WORK_DIR}/.gitconfig
echo "[credential]" >> ${WORK_DIR}/.gitconfig
echo "	helper = store --file ${WORK_DIR}/.git-credentials" >> ${WORK_DIR}/.gitconfig
echo "http://sc-admin:SecurePass123%21@${GITEA_HOST}" > ${WORK_DIR}/.git-credentials
chmod 600 ${WORK_DIR}/.git-credentials

p "8. Cloner le dépôt depuis Gitea"
pe "GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git clone ${GITEA_URL}/${GITEA_USER}/recipe-api.git ${WORK_DIR}/recipe-api"

p "9. Créer une branche pour le correctif"
cd "${WORK_DIR}/recipe-api"
pe "git checkout -b fix/pin-base-image-digest"

p "10. Préparer le Dockerfile sécurisé avec les vrais digests"
PATCHED_DOCKERFILE="${SCRIPT_DIR}/tekton-patched/Dockerfile"
sed "s|golang@sha256:PLACEHOLDER|golang@${GOLANG_DIGEST}|" "${PATCHED_DOCKERFILE}" | \
  sed "s|alpine@sha256:PLACEHOLDER|alpine@${ALPINE_DIGEST}|" > "${WORK_DIR}/recipe-api/Dockerfile"
pe "cat ${WORK_DIR}/recipe-api/Dockerfile"

p "11. Commit et push de la branche"
pe "git add Dockerfile"
pe "GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git commit -m 'fix: digest-pinned multi-stage Dockerfile'"

p "git push origin fix/pin-base-image-digest"
git remote set-url origin "http://${GITEA_USER}:SecurePass123%21@${GITEA_HOST}/${GITEA_USER}/recipe-api.git"
GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git push origin fix/pin-base-image-digest

cd "${SCRIPT_DIR}"

p "12. Créer une Pull Request vers la branche main"
PR_RESPONSE=$(curl -s -X POST \
  "${GITEA_URL}/api/v1/repos/${GITEA_USER}/recipe-api/pulls" \
  -H 'Content-Type: application/json' \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -d "{\"title\":\"fix: Dockerfile épinglé par digest avec multi-stage\",\"body\":\"Pin des images de base par digest et utilisation du build multi-stage\",\"base\":\"main\",\"head\":\"fix/pin-base-image-digest\"}")
echo "${PR_RESPONSE}" | jq .
PR_NUMBER=$(echo "${PR_RESPONSE}" | jq -r '.number')

BEFORE_PR_COUNT=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l)

p "============================================"
p "ACTION REQUISE : Fusionnez la PR #${PR_NUMBER}"
p "  1. Rendez-vous sur ${GITEA_URL}/${GITEA_USER}/recipe-api/pulls/${PR_NUMBER}"
p "  2. Cliquez sur 'Fusionner la pull request'"
p "  3. Revenez ici et appuyez sur Entrée"
p "============================================"

# ============================================================================
# PHASE 3 — Observer la pipeline sécurisée après fusion
# ============================================================================

p "  PHASE 3 — Pipeline sécurisée déclenchée par la fusion de la PR"

p "En attente du déclenchement du webhook..."
sleep 10
AFTER_PR_COUNT=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l)

if [ "$AFTER_PR_COUNT" -gt "$BEFORE_PR_COUNT" ]; then
    pe "kubectl get pipelineruns -n ci --sort-by=.metadata.creationTimestamp"
    p "Pipeline déclenchée automatiquement par le webhook"
    LATEST_PR_NAME=$(kubectl get pipelineruns -n ci --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    pe "tkn pr logs -f ${LATEST_PR_NAME} -n ci"
else
    p "Le webhook n'a pas déclenché de PipelineRun — déclenchement manuel"
    pe "kubectl create -f ${SCRIPT_DIR}/tekton-patched/manual-pipelinerun-with-chains-secure.yaml"
    sleep 3
    LATEST_PR_NAME=$(kubectl get pipelineruns -n ci --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    pe "tkn pr logs -f ${LATEST_PR_NAME} -n ci"
fi

pe "kubectl get pipelineruns -n ci"

# ============================================================================
# PHASE 4 — Vérification post-pipeline
# ============================================================================

p "  PHASE 4 — Vérification post-pipeline"

p "13. Vérifier l'image dans le registre"
pe "curl -k -s -u ${REGISTRY_USER}:${REGISTRY_PASS} ${REGISTRY_URL}/v2/recipe-api/tags/list"

p "14. Vérifier les artefacts attachés (SBOM, signature, scan, provenance)"
pe "SSL_CERT_FILE=${CA_CERT} oras discover \
  --plain-http=false \
  --registry-config ~/.docker/config.json \
  ${REGISTRY_HOST}/recipe-api:v3.0"

p "15. Vérifier les résultats du pipeline"
pe "kubectl get pipelinerun ${LATEST_PR_NAME} -n ci -o jsonpath='{.status.results}' | jq ."

# ============================================================================
# PHASE 5 — Vérification post-pipeline avec Conforma et Ampel
# ============================================================================

p "  PHASE 5 — Vérification post-pipeline avec Conforma et Ampel"

p "Attendre que Tekton Chains génère la provenance SLSA..."
sleep 10
IMAGE_DIGEST=$(kubectl get pipelinerun ${LATEST_PR_NAME} -n ci -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)
OIDC_ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')

p "Initialiser la racine de confiance TUF locale pour la vérification Sigstore"
TUF_ROOT_FILE=$(mktemp)
kubectl get configmap sigstore-tuf-root -n ci -o jsonpath='{.data.root\.json}' > "${TUF_ROOT_FILE}"
pe "cosign initialize --mirror=http://${TUF_HOST} --root=${TUF_ROOT_FILE}"
rm -f "${TUF_ROOT_FILE}"

if command -v ec &>/dev/null; then
    p "16. Conforma (Enterprise Contract) — vérification de conformité"
    p "  Identités attendues :"
    p "    - Pipeline : https://kubernetes.io/namespaces/ci/serviceaccounts/pipeline-keyless-signer"
    p "    - Tekton Chains : https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller"
    pe "SSL_CERT_FILE=${CA_CERT} ec validate image \
  --images '{\"components\":[{\"name\":\"recipe-api\",\"containerImage\":\"${REGISTRY_HOST}/recipe-api:v3.0@${IMAGE_DIGEST}\"}]}' \
  --policy '{\"sources\":[{\"name\":\"sbom-baseline\",\"policy\":[\"${SCRIPT_DIR}/security/conforma-policies/\"]}]}' \
  --certificate-identity-regexp 'https://kubernetes.io/namespaces/(ci|tekton-chains)/serviceaccounts/(pipeline-keyless-signer|tekton-chains-controller)' \
  --certificate-oidc-issuer ${OIDC_ISSUER} \
  --rekor-url http://${REKOR_HOST} \
  --extra-rule-data '\"allowed_registry_prefixes=[\"\"registry.registry.svc.cluster.local:5000\"\"]\"' \
  --output text 2>&1 || true"
else
    p "16. Conforma (ec) non installé — installer avec : make install-conforma"
fi

if command -v ampel &>/dev/null; then
    p "17. Ampel — vérification de la politique post-pipeline"
    p "  Vérifie que l'image possède :"
    p "    - Une attestation SBOM (in-toto, poussée par cosign attest)"
    p "    - Une provenance SLSA avec le bon builder ID (Tekton Chains)"

    pe "SSL_CERT_FILE=${CA_CERT} ampel verify \
  ${IMAGE_DIGEST} \
  --policy ${SCRIPT_DIR}/security/ampel-policies/verify-build-artifacts.hjson \
  --collector \"coci:${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST}\" \
  --context \"builderId:https://tekton.dev/chains/v2\" \
  --format tty 2>&1 || true"

    p "  Note : L'option --signer est omise car Ampel v1.2.1 ne supporte pas"
    p "  les racines Sigstore personnalisées (Fulcio/TUF local). La bibliothèque"
    p "  signer le permet via WithSigstoreRootsPath, mais le CLI ne l'expose pas."
    p "  Les signatures sont vérifiables directement avec cosign :"

    pe "cosign verify-attestation \
  --certificate-identity=https://kubernetes.io/namespaces/ci/serviceaccounts/pipeline-keyless-signer \
  --certificate-oidc-issuer=${OIDC_ISSUER} \
  --rekor-url=http://${REKOR_HOST} \
  --insecure-ignore-sct \
  --type spdxjson \
  --registry-cacert=${CA_CERT} \
  ${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST} 2>&1 | head -5 || true"

    p "  Quand Ampel supportera --sigstore-roots, la vérification complète sera :"
    p "    --signer 'sigstore:::${OIDC_ISSUER}:::https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller'"
    p "    --signer 'sigstore:::${OIDC_ISSUER}:::https://kubernetes.io/namespaces/ci/serviceaccounts/pipeline-keyless-signer'"
else
    p "17. Ampel non installé — installer avec : make install-ampel"
fi


p "✅"