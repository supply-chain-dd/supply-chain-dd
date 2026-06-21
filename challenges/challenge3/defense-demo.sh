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

source "${SCRIPT_DIR}/../../setup/scripts/check-sigstore.sh"
check_tuf_root
kubectl scale deployment tekton-chains-controller --replicas=0 -n tekton-chains

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

p "1. Déployer la pipeline sécurisée et ses ressources"
pei "make -C ${SCRIPT_DIR}/../.. setup-challenge3-tekton-secure"

# ============================================================================
# PHASE 1 — Pousser les images propres et créer une PR
# ============================================================================

p "2. Pousser les images propres, générer les SBOMs et les attacher..."
echo "  Push golang:1.25-alpine..."
podman pull golang:1.25-alpine 2>/dev/null
podman tag golang:1.25-alpine ${REGISTRY_HOST}/golang:1.25-alpine
podman push ${REGISTRY_HOST}/golang:1.25-alpine 2>/dev/null
echo "  Push alpine:3.20..."
podman pull alpine:3.20 2>/dev/null
podman tag alpine:3.20 ${REGISTRY_HOST}/alpine:3.20
podman push ${REGISTRY_HOST}/alpine:3.20 2>/dev/null

GOLANG_DIGEST=$(skopeo inspect docker://${REGISTRY_HOST}/golang:1.25-alpine 2>/dev/null | jq -r .Digest)
ALPINE_DIGEST=$(skopeo inspect docker://${REGISTRY_HOST}/alpine:3.20 2>/dev/null | jq -r .Digest)

echo "  Génération et attachement des SBOMs via Job..."
kubectl delete job generate-sbom-baseline -n ci --ignore-not-found 2>/dev/null
kubectl create -f ${SCRIPT_DIR}/tekton-patched/jobs/generate-sbom-baseline-job.yaml 2>/dev/null
kubectl wait --for=condition=complete job/generate-sbom-baseline -n ci --timeout=300s 2>/dev/null
BASELINE_POD=$(kubectl get pods -n ci -l job-name=generate-sbom-baseline -o jsonpath='{.items[0].metadata.name}')
kubectl logs ${BASELINE_POD} -n ci | sed -n '/^===BASELINE_JSON_START===/,/^===BASELINE_JSON_END===/{ //!p; }' > ${WORK_DIR}/baseline-packages.json
kubectl create configmap golang-baseline-sbom \
  --namespace ci \
  --from-file=baseline-packages.json=${WORK_DIR}/baseline-packages.json \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
kubectl delete job generate-sbom-baseline -n ci --ignore-not-found 2>/dev/null

pe "echo \"golang digest: ${GOLANG_DIGEST}\""
pe "echo \"alpine digest: ${ALPINE_DIGEST}\""
p "Conseil : Activez les tags immuables sur votre registre si disponible"

# --- Git setup ---
echo "[user]" > ${WORK_DIR}/.gitconfig
echo "	name = SC Admin" >> ${WORK_DIR}/.gitconfig
echo "	email = sc-admin@localhost" >> ${WORK_DIR}/.gitconfig
echo "[credential]" >> ${WORK_DIR}/.gitconfig
echo "	helper = store --file ${WORK_DIR}/.git-credentials" >> ${WORK_DIR}/.gitconfig
echo "http://sc-admin:SecurePass123%21@${GITEA_HOST}" > ${WORK_DIR}/.git-credentials
chmod 600 ${WORK_DIR}/.git-credentials

p "3. Préparer le Dockerfile sécurisé avec les vrais digests"
GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git clone ${GITEA_URL}/${GITEA_USER}/recipe-api.git ${WORK_DIR}/recipe-api 2>/dev/null
cd "${WORK_DIR}/recipe-api"
git checkout -b fix/pin-base-image-digest 2>/dev/null

PATCHED_DOCKERFILE="${SCRIPT_DIR}/tekton-patched/Dockerfile"
sed "s|golang@sha256:PLACEHOLDER|golang@${GOLANG_DIGEST}|" "${PATCHED_DOCKERFILE}" | \
  sed "s|alpine@sha256:PLACEHOLDER|alpine@${ALPINE_DIGEST}|" > "${WORK_DIR}/recipe-api/Dockerfile"
pe "cat ${WORK_DIR}/recipe-api/Dockerfile"

p "4. Commit, push et créer une Pull Request"
pe "git add Dockerfile"
pe "GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git commit -m 'fix: digest-pinned multi-stage Dockerfile'"

git remote set-url origin "http://${GITEA_USER}:SecurePass123%21@${GITEA_HOST}/${GITEA_USER}/recipe-api.git"
pe "GIT_CONFIG_GLOBAL=${WORK_DIR}/.gitconfig git push origin fix/pin-base-image-digest"

cd "${SCRIPT_DIR}"

PR_RESPONSE=$(curl -s -X POST \
  "${GITEA_URL}/api/v1/repos/${GITEA_USER}/recipe-api/pulls" \
  -H 'Content-Type: application/json' \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -d "{\"title\":\"fix: Dockerfile épinglé par digest avec multi-stage\",\"body\":\"Pin des images de base par digest et utilisation du build multi-stage\",\"base\":\"main\",\"head\":\"fix/pin-base-image-digest\"}")
# pe "echo '${PR_RESPONSE}' | jq ."
PR_NUMBER=$(echo "${PR_RESPONSE}" | jq -r '.number')

BEFORE_PR_COUNT=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l)

p "============================================"
p "ACTION REQUISE : Merge ${GITEA_URL}/${GITEA_USER}/recipe-api/pulls/${PR_NUMBER}"
p "============================================"

# ============================================================================
# PHASE 2 — Observer la pipeline sécurisée après fusion
# ============================================================================

p "En attente du déclenchement du webhook..."
sleep 2
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
# PHASE 3 — Vérification post-pipeline
# ============================================================================

p "5. Vérifier les résultats du pipeline"
pe "kubectl get pipelinerun ${LATEST_PR_NAME} -n ci -o jsonpath='{.status.results}' | jq ."

IMAGE_DIGEST=$(kubectl get pipelinerun ${LATEST_PR_NAME} -n ci -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)
OIDC_ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')

TUF_ROOT_FILE=$(mktemp)
kubectl get configmap sigstore-tuf-root -n ci -o jsonpath='{.data.root\.json}' > "${TUF_ROOT_FILE}"
cosign initialize --mirror=http://${TUF_HOST} --root=${TUF_ROOT_FILE} 2>/dev/null
rm -f "${TUF_ROOT_FILE}"

p "6. Artefacts attachés à l'image (SBOM, signature, scan, provenance)"
pe "cosign tree --registry-cacert=${CA_CERT} ${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST} 2>/dev/null || echo 'cosign tree non disponible'"

# ============================================================================
# PHASE 4 — Attestations de provenance et SBOM
# ============================================================================

p "7. Attestation de provenance SLSA — builder, source et artefacts attestés"
pe "cosign verify-attestation \
  --certificate-identity=https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller \
  --certificate-oidc-issuer=${OIDC_ISSUER} \
  --rekor-url=http://${REKOR_HOST} \
  --insecure-ignore-sct \
  --new-bundle-format=false \
  --type slsaprovenance \
  --registry-cacert=${CA_CERT} \
  ${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST} 2>/dev/null \
  | jq -r '.payload' | base64 -d > ${WORK_DIR}/provenance.json"

pe "cat ${WORK_DIR}/provenance.json| jq | bat"

pe "cat ${WORK_DIR}/provenance.json | jq '{
  predicateType,
  builder: .predicate.builder.id,
  materials: [.predicate.materials[] | {uri, digest}],
  subjects: [.subject[] | {name: .name, sha256: .digest.sha256[:16]}]
}'"

# p "8. Attestation SBOM signée (cosign attest en pipeline)"
# pe "cosign verify-attestation \
#   --certificate-identity=https://kubernetes.io/namespaces/ci/serviceaccounts/pipeline-keyless-signer \
#   --certificate-oidc-issuer=${OIDC_ISSUER} \
#   --rekor-url=http://${REKOR_HOST} \
#   --insecure-ignore-sct \
#   --type spdxjson \
#   --registry-cacert=${CA_CERT} \
#   ${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST} 2>/dev/null \
#   | jq -r '.payload' | base64 -d | jq '{predicateType: .predicateType, packageCount: (.predicate.packages | length), topPackages: [.predicate.packages[:5][] | .name]}'"

p "✅"