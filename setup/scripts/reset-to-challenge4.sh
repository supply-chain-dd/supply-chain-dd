#!/bin/bash
#
# Reset Environment to Challenge 4 Starting State
# Brings the environment to the "end of Challenge 3 defense" state:
#   - Challenge 2 baseline resources intact
#   - Challenge 3 secured pipeline deployed (push-build-pipeline-with-chains-secure)
#   - Secured pipeline has been run: attested image exists (SBOM, signature, provenance)
#   - golang-baseline-sbom ConfigMap created
#   - Digest-pinned Dockerfile committed in Gitea
#   - Basic release-pipeline namespace infrastructure ready (no challenge4-secure resources)
#   - Tekton Chains running, Sigstore stack accessible
# Safe to run multiple times (idempotent).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/../.."
source "${SCRIPT_DIR}/domains.sh"

CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
GITEA_URL="http://${GITEA_HOST}"
GITEA_USER="${GITEA_USER:-sc-admin}"
GITEA_PASS="${GITEA_PASS:-SecurePass123!}"
REPO_NAME="${REPO_NAME:-recipe-api}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-change-me-in-production}"
REGISTRY_USER="${REGISTRY_USER:-sc-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-RegistryPass123!}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
CHALLENGE2_DIR="${PROJECT_ROOT}/challenges/challenge2"
CHALLENGE3_DIR="${PROJECT_ROOT}/challenges/challenge3"
CHALLENGE4_DIR="${PROJECT_ROOT}/challenges/challenge4"
E2E_DIR="${PROJECT_ROOT}/challenges/e2e-scenario"
CA_CERT="${PROJECT_ROOT}/setup/certs/registry.crt"

echo "=========================================="
echo "Reset to Challenge 4 Starting State"
echo "=========================================="
echo ""

# ──────────────────────────────────────────────
# [1/18] Prerequisites
# ──────────────────────────────────────────────
echo "[1/18] Checking prerequisites..."

if ! kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo "  ❌ KinD cluster '$CLUSTER_NAME' not found"
    echo "     Run: make setup"
    exit 1
fi
echo "  ✓ KinD cluster exists"

kubectl config use-context "kind-$CLUSTER_NAME" > /dev/null 2>&1 || {
    echo "  ❌ Cannot switch to kind-$CLUSTER_NAME context"
    exit 1
}
echo "  ✓ kubectl context set"

kubectl get nodes > /dev/null 2>&1 || {
    echo "  ❌ Cluster not responding"
    exit 1
}
echo "  ✓ Cluster is responsive"

kubectl get pods -n tekton-pipelines 2>/dev/null | grep -q Running || {
    echo "  ❌ Tekton Pipelines not running"
    echo "     Run: make setup-tekton"
    exit 1
}
echo "  ✓ Tekton Pipelines running"

kubectl get deployment tekton-triggers-controller -n tekton-pipelines > /dev/null 2>&1 || {
    echo "  ❌ Tekton Triggers not installed"
    echo "     Run: make setup-tekton"
    exit 1
}
echo "  ✓ Tekton Triggers installed"

if ! curl -f -s -o /dev/null "$GITEA_URL"; then
    echo "  ❌ Gitea not accessible at $GITEA_URL"
    echo "     Run: make setup-gitea"
    exit 1
fi
echo "  ✓ Gitea accessible"

if ! command -v "$CONTAINER_RUNTIME" &>/dev/null; then
    echo "  ❌ Container runtime '$CONTAINER_RUNTIME' not found"
    exit 1
fi
echo "  ✓ Container runtime: $CONTAINER_RUNTIME"

if ! command -v skopeo &>/dev/null; then
    echo "  ❌ skopeo not found (needed for digest inspection)"
    exit 1
fi
echo "  ✓ skopeo available"

kubectl get namespace tekton-chains > /dev/null 2>&1 || {
    echo "  ❌ Tekton Chains not installed"
    echo "     Run: make setup-tektonchains"
    exit 1
}
echo "  ✓ Tekton Chains namespace exists"

kubectl get configmap sigstore-tuf-root -n ci > /dev/null 2>&1 || {
    echo "  ❌ Sigstore TUF root ConfigMap not found in ci namespace"
    echo "     Run: make setup-sigstore-local"
    exit 1
}
echo "  ✓ Sigstore TUF root ConfigMap exists"

kubectl create namespace ci 2>/dev/null && echo "  ✓ Created ci namespace" || echo "  ✓ ci namespace exists"
echo ""

# ──────────────────────────────────────────────
# [2/18] Clean completed runs
# ──────────────────────────────────────────────
echo "[2/18] Cleaning completed pipeline runs and pods..."

PR_COUNT=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")
TR_COUNT=$(kubectl get taskruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")

for pr in $(kubectl get pipelineruns -n ci -o name 2>/dev/null); do
    kubectl patch "$pr" -n ci --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done
kubectl delete pipelineruns --all -n ci --ignore-not-found 2>/dev/null || true

for tr in $(kubectl get taskruns -n ci -o name 2>/dev/null); do
    kubectl patch "$tr" -n ci --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done
kubectl delete taskruns --all -n ci --ignore-not-found 2>/dev/null || true
kubectl delete pods --field-selector=status.phase!=Running -n ci --ignore-not-found 2>/dev/null || true

echo "  ✓ Cleaned $PR_COUNT PipelineRun(s), $TR_COUNT TaskRun(s)"

if kubectl get namespace release-pipeline > /dev/null 2>&1; then
    for pr in $(kubectl get pipelineruns -n release-pipeline -o name 2>/dev/null); do
        kubectl patch "$pr" -n release-pipeline --type=json \
            -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
    kubectl delete pipelineruns --all -n release-pipeline --ignore-not-found 2>/dev/null || true
    for tr in $(kubectl get taskruns -n release-pipeline -o name 2>/dev/null); do
        kubectl patch "$tr" -n release-pipeline --type=json \
            -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
    kubectl delete taskruns --all -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete pods --field-selector=status.phase!=Running -n release-pipeline --ignore-not-found 2>/dev/null || true
    echo "  ✓ Cleaned release-pipeline namespace runs"
fi
echo ""

# ──────────────────────────────────────────────
# [3/18] Remove challenge 1 secure resources
# ──────────────────────────────────────────────
echo "[3/18] Removing challenge 1 secure/defense resources..."

kubectl delete sa pr-pipeline-readonly main-pipeline security-auditor -n ci --ignore-not-found 2>/dev/null || true
kubectl delete role pr-pipeline-minimal main-pipeline-privileged -n ci --ignore-not-found 2>/dev/null || true
kubectl delete rolebinding pr-pipeline-readonly-binding main-pipeline-binding -n ci --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole security-auditor --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding security-auditor-binding --ignore-not-found 2>/dev/null || true

kubectl delete clusterpolicy block-dangerous-task-commands restrict-external-git-repositories \
    restrict-tekton-pr-pipelines --ignore-not-found 2>/dev/null || true

kubectl delete networkpolicy ci-egress-restriction -n ci --ignore-not-found 2>/dev/null || true
kubectl delete networkpolicy tekton-pipelines-egress-restriction -n tekton-pipelines --ignore-not-found 2>/dev/null || true

echo "  ✓ Challenge 1 secure resources removed"
echo ""

# ──────────────────────────────────────────────
# [4/18] Remove challenge 2 patched resources
# ──────────────────────────────────────────────
echo "[4/18] Removing challenge 2 patched/defense resources..."

kubectl delete pipeline push-build-pipeline-secure -n ci --ignore-not-found 2>/dev/null || true

echo "  ✓ Challenge 2 patched resources removed"
echo ""

# ──────────────────────────────────────────────
# [5/18] Remove challenge 4 resources from release-pipeline
# ──────────────────────────────────────────────
echo "[5/18] Removing challenge 4 resources from release-pipeline namespace..."

if kubectl get namespace release-pipeline > /dev/null 2>&1; then
    kubectl delete pipeline release-pipeline-secure -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete task verify-image-policy -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete eventlistener release-pipeline-secure-listener -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete triggertemplate release-pipeline-secure-template -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete triggerbinding release-pipeline-secure-binding -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete sa release-triggers-sa -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete role release-triggers-role -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete rolebinding release-triggers-rolebinding -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete clusterrolebinding release-triggers-clusterbinding --ignore-not-found 2>/dev/null || true
    kubectl delete configmap conforma-sbom-policy -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete configmap sigstore-tuf-root -n release-pipeline --ignore-not-found 2>/dev/null || true
    echo "  ✓ Challenge 4 resources removed from release-pipeline"
else
    echo "  ✓ release-pipeline namespace does not exist (nothing to clean)"
fi
echo ""

# ──────────────────────────────────────────────
# [6/18] Remove challenge 4 resources from ci
# ──────────────────────────────────────────────
echo "[6/18] Removing challenge 4 resources from ci namespace..."

kubectl delete pipeline push-build-pipeline-with-release-gate -n ci --ignore-not-found 2>/dev/null || true
kubectl delete task notify-release-verified -n ci --ignore-not-found 2>/dev/null || true
kubectl delete rolebinding pipeline-keyless-signer-taskrun-reader -n ci --ignore-not-found 2>/dev/null || true
kubectl delete role taskrun-reader -n ci --ignore-not-found 2>/dev/null || true

echo "  ✓ Challenge 4 resources removed from ci"
echo ""

# ──────────────────────────────────────────────
# [7/18] Apply challenge 2 baseline resources
# ──────────────────────────────────────────────
echo "[7/18] Applying challenge 2 baseline Tekton resources..."

kubectl apply -f "${CHALLENGE2_DIR}/tekton/gitea-credentials.yaml"
kubectl apply -f "${CHALLENGE2_DIR}/tekton/serviceaccounts.yaml"
kubectl apply -f "${CHALLENGE2_DIR}/tekton/serviceaccounts-keyless.yaml"
kubectl apply -f "${CHALLENGE2_DIR}/tekton/registry-docker-config-secret.yaml"
kubectl apply -f "${CHALLENGE2_DIR}/tekton/tasks/"
kubectl apply -f "${CHALLENGE2_DIR}/tekton/pipelines/"
kubectl apply -f "${CHALLENGE2_DIR}/tekton/triggers/"

kubectl create secret generic registry-credentials \
    --from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us:NEXT:registry_layer_leak}' \
    --from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
    --from-literal=registry-user="${REGISTRY_USER}" \
    --from-literal=registry-password="${REGISTRY_PASS}" \
    -n ci --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ Challenge 2 baseline resources applied"
echo ""

# ──────────────────────────────────────────────
# [8/18] Apply challenge 3 defense resources
# ──────────────────────────────────────────────
echo "[8/18] Applying challenge 3 defense resources (secured pipeline)..."

kubectl apply -f "${CHALLENGE3_DIR}/tekton/tasks/"
kubectl apply -f "${CHALLENGE3_DIR}/tekton/pipelines/"
kubectl apply -f "${CHALLENGE3_DIR}/tekton-patched/tasks/"
kubectl apply -f "${CHALLENGE3_DIR}/tekton-patched/pipelines/"
kubectl apply -f "${CHALLENGE3_DIR}/tekton-patched/triggers/"

echo "  ✓ Challenge 3 secured pipeline deployed"
echo ""

# ──────────────────────────────────────────────
# [9/18] Ensure Tekton Chains is running
# ──────────────────────────────────────────────
echo "[9/18] Ensuring Tekton Chains controller is running..."

CURRENT_REPLICAS=$(kubectl get deployment tekton-chains-controller -n tekton-chains -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "$CURRENT_REPLICAS" = "0" ]; then
    kubectl scale deployment tekton-chains-controller --replicas=1 -n tekton-chains
    echo "  ✓ Tekton Chains controller scaled back up"
else
    echo "  ✓ Tekton Chains controller already running"
fi
echo ""

# ──────────────────────────────────────────────
# [10/18] Push clean base images to registry
# ──────────────────────────────────────────────
echo "[10/18] Pushing clean base images to registry..."

$CONTAINER_RUNTIME pull golang:1.25-alpine 2>/dev/null || true
$CONTAINER_RUNTIME tag golang:1.25-alpine "${REGISTRY_HOST}/golang:1.25-alpine"
$CONTAINER_RUNTIME login "${REGISTRY_HOST}" \
    -u "$REGISTRY_USER" -p "$REGISTRY_PASS" 2>/dev/null || true
$CONTAINER_RUNTIME push "${REGISTRY_HOST}/golang:1.25-alpine"
echo "  ✓ Clean golang:1.25-alpine pushed to registry"

$CONTAINER_RUNTIME pull alpine:3.20 2>/dev/null || true
$CONTAINER_RUNTIME tag alpine:3.20 "${REGISTRY_HOST}/alpine:3.20"
$CONTAINER_RUNTIME push "${REGISTRY_HOST}/alpine:3.20"
echo "  ✓ Clean alpine:3.20 pushed to registry"
echo ""

# ──────────────────────────────────────────────
# [11/18] Get image digests
# ──────────────────────────────────────────────
echo "[11/18] Getting base image digests..."

GOLANG_DIGEST=$(skopeo inspect docker://${REGISTRY_HOST}/golang:1.25-alpine | jq -r .Digest)
ALPINE_DIGEST=$(skopeo inspect docker://${REGISTRY_HOST}/alpine:3.20 | jq -r .Digest)

echo "  golang digest: ${GOLANG_DIGEST}"
echo "  alpine digest: ${ALPINE_DIGEST}"
echo ""

# ──────────────────────────────────────────────
# [12/18] Generate SBOM baseline
# ──────────────────────────────────────────────
echo "[12/18] Running generate-sbom-baseline Job (SBOMs + OCI referrers)..."

kubectl delete job generate-sbom-baseline -n ci --ignore-not-found 2>/dev/null
kubectl create -f "${CHALLENGE3_DIR}/tekton-patched/jobs/generate-sbom-baseline-job.yaml"

echo "  Waiting for Job pod to be ready..."
kubectl wait --for=condition=ready pod -l job-name=generate-sbom-baseline -n ci --timeout=300s 2>/dev/null || {
    echo "  ❌ generate-sbom-baseline pod did not become ready"
    echo "     Check: kubectl describe job generate-sbom-baseline -n ci"
    exit 1
}

echo "  Waiting for Job completion..."
kubectl wait --for=condition=complete job/generate-sbom-baseline -n ci --timeout=300s 2>/dev/null || {
    echo "  ❌ generate-sbom-baseline Job did not complete"
    BASELINE_POD=$(kubectl get pods -n ci -l job-name=generate-sbom-baseline -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    echo "     Check logs: kubectl logs ${BASELINE_POD} -n ci"
    exit 1
}

echo "  ✓ SBOM baseline Job completed"
echo ""

# ──────────────────────────────────────────────
# [13/18] Create golang-baseline-sbom ConfigMap
# ──────────────────────────────────────────────
echo "[13/18] Creating golang-baseline-sbom ConfigMap..."

WORK_DIR=$(mktemp -d)
BASELINE_POD=$(kubectl get pods -n ci -l job-name=generate-sbom-baseline -o jsonpath='{.items[0].metadata.name}')
kubectl logs "${BASELINE_POD}" -n ci | \
    sed -n '/^===BASELINE_JSON_START===/,/^===BASELINE_JSON_END===/{ //!p; }' \
    > "${WORK_DIR}/baseline-packages.json"

BASELINE_COUNT=$(jq '[.[] | length] | add' "${WORK_DIR}/baseline-packages.json" 2>/dev/null || echo "0")
BASELINE_IMAGES=$(jq 'keys | length' "${WORK_DIR}/baseline-packages.json" 2>/dev/null || echo "0")
if [ "$BASELINE_COUNT" = "0" ] || [ "$BASELINE_COUNT" = "null" ]; then
    echo "  ❌ Baseline JSON is empty — check Job logs"
    echo "     kubectl logs ${BASELINE_POD} -n ci"
    rm -rf "$WORK_DIR"
    exit 1
fi

kubectl create configmap golang-baseline-sbom \
    --namespace ci \
    --from-file=baseline-packages.json="${WORK_DIR}/baseline-packages.json" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl delete job generate-sbom-baseline -n ci --ignore-not-found 2>/dev/null
rm -rf "$WORK_DIR"

echo "  ✓ golang-baseline-sbom ConfigMap created (${BASELINE_COUNT} packages across ${BASELINE_IMAGES} images)"
echo ""

# ──────────────────────────────────────────────
# [14/18] Fix Dockerfile in Gitea
# ──────────────────────────────────────────────
echo "[14/18] Restoring Gitea repo with digest-pinned Dockerfile..."

# Delete ALL existing webhooks BEFORE any pushes to prevent spurious PipelineRuns
EXISTING_WEBHOOKS=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" 2>/dev/null || echo "[]")
for id in $(echo "$EXISTING_WEBHOOKS" | jq -r '.[].id' 2>/dev/null); do
    curl -s -X DELETE \
        -u "$GITEA_USER:$GITEA_PASS" \
        "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks/$id" >/dev/null 2>&1
done
echo "  ✓ Existing webhooks deleted (prevents spurious pipeline triggers)"

# Remove branch protection
curl -s -X DELETE \
    -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/branch_protections/main" >/dev/null 2>&1 || true

# Delete defense-demo branches
curl -s -X DELETE \
    -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/branches/fix/pin-base-image-digest" >/dev/null 2>&1 || true

# Re-seed the repository (restores base git history)
"${SCRIPT_DIR}/seed-victim-repo.sh"
echo "  ✓ Victim repository re-seeded"

# Clone, apply challenge2 fix, then challenge3 digest-pinned fix
REPO_WORK_DIR=$(mktemp -d)
GIT_CRED_FILE=$(mktemp)
GIT_CONFIG_FILE=$(mktemp)
echo "http://${GITEA_USER}:SecurePass123%21@${GITEA_HOST}" > "$GIT_CRED_FILE"
chmod 600 "$GIT_CRED_FILE"
cat > "$GIT_CONFIG_FILE" <<GITCFG
[user]
	name = SC Admin
	email = sc-admin@localhost
[credential]
	helper = store --file ${GIT_CRED_FILE}
GITCFG

GIT_CONFIG_GLOBAL="$GIT_CONFIG_FILE" git clone "${GITEA_URL}/${GITEA_USER}/${REPO_NAME}.git" "${REPO_WORK_DIR}/${REPO_NAME}" 2>/dev/null

# First commit: challenge2 multi-stage fix
cp "${CHALLENGE2_DIR}/tekton-patched/Dockerfile" "${REPO_WORK_DIR}/${REPO_NAME}/Dockerfile"
cp "${CHALLENGE2_DIR}/tekton-patched/.dockerignore" "${REPO_WORK_DIR}/${REPO_NAME}/.dockerignore"

cd "${REPO_WORK_DIR}/${REPO_NAME}"
git add Dockerfile .dockerignore
GIT_CONFIG_GLOBAL="$GIT_CONFIG_FILE" git commit -m 'fix: multi-stage build + .dockerignore' 2>/dev/null
echo "  ✓ Applied challenge 2 fix (multi-stage Dockerfile)"

# Second commit: challenge3 digest-pinned Dockerfile
PATCHED_DOCKERFILE="${CHALLENGE3_DIR}/tekton-patched/Dockerfile"
sed "s|golang@sha256:PLACEHOLDER|golang@${GOLANG_DIGEST}|" "${PATCHED_DOCKERFILE}" | \
    sed "s|alpine@sha256:PLACEHOLDER|alpine@${ALPINE_DIGEST}|" > "${REPO_WORK_DIR}/${REPO_NAME}/Dockerfile"

git add Dockerfile
GIT_CONFIG_GLOBAL="$GIT_CONFIG_FILE" git commit -m 'fix: digest-pinned multi-stage Dockerfile' 2>/dev/null
echo "  ✓ Applied challenge 3 fix (digest-pinned Dockerfile)"

git remote set-url origin "http://${GITEA_USER}:SecurePass123%21@${GITEA_HOST}/${GITEA_USER}/${REPO_NAME}.git"
GIT_CONFIG_GLOBAL="$GIT_CONFIG_FILE" git push origin main 2>/dev/null
cd "$PROJECT_ROOT"

rm -rf "$REPO_WORK_DIR" "$GIT_CRED_FILE" "$GIT_CONFIG_FILE"
echo "  ✓ Dockerfile pushed to Gitea"
echo ""

# ──────────────────────────────────────────────
# [15/18] Configure webhooks
# ──────────────────────────────────────────────
echo "[15/18] Configuring Gitea webhooks..."

EXISTING_WEBHOOKS=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" 2>/dev/null || echo "[]")

# -- Push webhook --
PUSH_LISTENER_URL="http://el-push-build-listener.ci.svc.cluster.local:8080"
PUSH_WEBHOOK_IDS=$(echo "$EXISTING_WEBHOOKS" | \
    jq -r '.[] | select(.events | contains(["push"])) | .id' 2>/dev/null || echo "")
if [ -n "$PUSH_WEBHOOK_IDS" ]; then
    for id in $PUSH_WEBHOOK_IDS; do
        curl -s -X DELETE \
            -u "$GITEA_USER:$GITEA_PASS" \
            "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks/$id" >/dev/null 2>&1
    done
fi

PUSH_RESULT=$(curl -s -X POST \
    -u "$GITEA_USER:$GITEA_PASS" \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"gitea\",
      \"config\": {
        \"url\": \"$PUSH_LISTENER_URL\",
        \"content_type\": \"json\",
        \"secret\": \"$WEBHOOK_SECRET\"
      },
      \"events\": [\"push\"],
      \"active\": true
    }" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks")

if echo "$PUSH_RESULT" | jq -e '.id' > /dev/null 2>&1; then
    PUSH_WH_ID=$(echo "$PUSH_RESULT" | jq -r '.id')
    echo "  ✓ Push webhook created (ID: $PUSH_WH_ID) → $PUSH_LISTENER_URL"
else
    echo "  ❌ Failed to create push webhook"
    echo "$PUSH_RESULT" | jq '.' 2>/dev/null || echo "$PUSH_RESULT"
    exit 1
fi

# -- PR webhook --
EXISTING_WEBHOOKS=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" 2>/dev/null || echo "[]")

PR_LISTENER_URL="http://el-pr-quality-check-listener.ci.svc.cluster.local:8080"
PR_WEBHOOK_IDS=$(echo "$EXISTING_WEBHOOKS" | \
    jq -r '.[] | select(.events | contains(["pull_request"])) | .id' 2>/dev/null || echo "")
if [ -n "$PR_WEBHOOK_IDS" ]; then
    for id in $PR_WEBHOOK_IDS; do
        curl -s -X DELETE \
            -u "$GITEA_USER:$GITEA_PASS" \
            "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks/$id" >/dev/null 2>&1
    done
fi

PR_RESULT=$(curl -s -X POST \
    -u "$GITEA_USER:$GITEA_PASS" \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"gitea\",
      \"config\": {
        \"url\": \"$PR_LISTENER_URL\",
        \"content_type\": \"json\",
        \"secret\": \"$WEBHOOK_SECRET\"
      },
      \"events\": [\"pull_request\"],
      \"active\": true
    }" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks")

if echo "$PR_RESULT" | jq -e '.id' > /dev/null 2>&1; then
    PR_WH_ID=$(echo "$PR_RESULT" | jq -r '.id')
    echo "  ✓ PR webhook created (ID: $PR_WH_ID) → $PR_LISTENER_URL"
else
    echo "  ❌ Failed to create PR webhook"
    echo "$PR_RESULT" | jq '.' 2>/dev/null || echo "$PR_RESULT"
    exit 1
fi
echo ""

# ──────────────────────────────────────────────
# [16/18] Run secured pipeline and wait
# ──────────────────────────────────────────────
echo "[16/18] Running challenge 3 secured pipeline..."

LATEST_PR_NAME=$(kubectl create -f "${CHALLENGE3_DIR}/tekton-patched/manual-pipelinerun-with-chains-secure.yaml" -o jsonpath='{.metadata.name}')
sleep 3
echo "  PipelineRun: $LATEST_PR_NAME"

# Phase A: wait for pipeline completion
PIPELINE_TIMEOUT=600
ELAPSED=0
STATUS=""
while [ $ELAPSED -lt $PIPELINE_TIMEOUT ]; do
    STATUS=$(kubectl get pipelinerun "$LATEST_PR_NAME" -n ci \
        -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Pending")

    if [ "$STATUS" = "Succeeded" ]; then
        echo "  ✓ Pipeline completed successfully (${ELAPSED}s)"
        break
    elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "PipelineRunTimeout" ]; then
        echo "  ❌ Pipeline FAILED with status: $STATUS"
        echo "     Check logs: tkn pr logs $LATEST_PR_NAME -n ci"
        exit 1
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    echo "  waiting for pipeline... (${ELAPSED}s/${PIPELINE_TIMEOUT}s) status=$STATUS"
done

if [ "$STATUS" != "Succeeded" ]; then
    echo "  ❌ Timeout: pipeline did not complete within ${PIPELINE_TIMEOUT}s"
    echo "     Check: kubectl get pipelinerun $LATEST_PR_NAME -n ci -o yaml"
    exit 1
fi

# Phase B: wait for Tekton Chains to sign
echo "  Waiting for Tekton Chains to sign..."
CHAINS_TIMEOUT=180
ELAPSED=0
SIGNED=""
while [ $ELAPSED -lt $CHAINS_TIMEOUT ]; do
    SIGNED=$(kubectl get taskruns -n ci \
        -l "tekton.dev/pipelineRun=${LATEST_PR_NAME},tekton.dev/pipelineTask=push-container-image" \
        -o jsonpath='{.items[0].metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || echo "")

    if [ "$SIGNED" = "true" ]; then
        echo "  ✓ Tekton Chains signing completed (${ELAPSED}s)"
        break
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "  waiting for Chains signing... (${ELAPSED}s/${CHAINS_TIMEOUT}s)"
done

if [ "$SIGNED" != "true" ]; then
    echo "  ⚠ Warning: Chains did not sign within ${CHAINS_TIMEOUT}s"
    echo "    Continuing anyway — cosign verification may fail in demos"
    echo "    Check: kubectl get taskruns -n ci -l tekton.dev/pipelineRun=${LATEST_PR_NAME} -o yaml"
fi

IMAGE_DIGEST=$(kubectl get pipelinerun "$LATEST_PR_NAME" -n ci \
    -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)
echo "  Image digest: $IMAGE_DIGEST"
echo ""

# ──────────────────────────────────────────────
# [17/18] Set up basic release pipeline
# ──────────────────────────────────────────────
echo "[17/18] Setting up basic release pipeline infrastructure..."

kubectl create namespace release-pipeline 2>/dev/null || true

kubectl create secret docker-registry ci-registry-credentials \
    --docker-server=registry.registry.svc.cluster.local:5000 \
    --docker-username="$REGISTRY_USER" --docker-password="$REGISTRY_PASS" \
    -n release-pipeline --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry production-registry-credentials \
    --docker-server=registry-prod.sc.local:31443 \
    --docker-username="$REGISTRY_USER" --docker-password="$REGISTRY_PASS" \
    -n release-pipeline --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap ci-registry-ca-cert \
    --from-file=ca.crt="${CA_CERT}" \
    -n release-pipeline --dry-run=client -o yaml | kubectl apply -f -

if [ -f "${PROJECT_ROOT}/setup/certs/production-registry.crt" ]; then
    kubectl create configmap production-registry-ca-cert \
        --from-file=ca.crt="${PROJECT_ROOT}/setup/certs/production-registry.crt" \
        -n release-pipeline --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl create secret generic production-gitea-credentials \
    --from-literal=username=sc-admin --from-literal=password=SecurePass123! \
    -n release-pipeline --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${E2E_DIR}/tekton/release-namespace.yaml"
kubectl apply -f "${E2E_DIR}/tekton/tasks/release-tasks.yaml"
kubectl apply -f "${E2E_DIR}/tekton/pipelines/release-pipeline.yaml"
kubectl apply -f "${E2E_DIR}/tekton/triggers/release-eventlistener.yaml"

echo "  ✓ Basic release pipeline infrastructure deployed"
echo ""

# ──────────────────────────────────────────────
# [18/18] Verify
# ──────────────────────────────────────────────
echo "[18/18] Verifying challenge 4 readiness..."
echo ""

EXIT_CODE=0

check_item() {
    local description=$1
    local command=$2
    echo -n "  $description... "
    if eval "$command" > /dev/null 2>&1; then
        echo "✓"
        return 0
    else
        echo "❌"
        return 1
    fi
}

echo "  Challenge 2 baseline (pipelines & triggers):"
check_item "push-build-pipeline" "kubectl get pipeline push-build-pipeline -n ci" || EXIT_CODE=1
check_item "push-build-pipeline-keyless" "kubectl get pipeline push-build-pipeline-keyless -n ci" || EXIT_CODE=1
check_item "Push EventListener" "kubectl get eventlistener push-build-listener -n ci" || EXIT_CODE=1
check_item "PR EventListener" "kubectl get eventlistener pr-quality-check-listener -n ci" || EXIT_CODE=1

echo ""
echo "  Challenge 3 secured pipeline:"
check_item "push-build-pipeline-with-chains-secure" "kubectl get pipeline push-build-pipeline-with-chains-secure -n ci" || EXIT_CODE=1
check_item "verify-base-image task" "kubectl get task verify-base-image -n ci" || EXIT_CODE=1
check_item "attest-sbom-keyless task" "kubectl get task attest-sbom-keyless -n ci" || EXIT_CODE=1
check_item "sign-image-keyless task" "kubectl get task sign-image-keyless -n ci" || EXIT_CODE=1
check_item "generate-sbom task" "kubectl get task generate-sbom -n ci" || EXIT_CODE=1
check_item "scan-image task" "kubectl get task scan-image -n ci" || EXIT_CODE=1
check_item "create-source-vsa task" "kubectl get task create-source-vsa -n ci" || EXIT_CODE=1

echo ""
echo "  RBAC & Secrets:"
check_item "challenge2-pipeline SA" "kubectl get sa challenge2-pipeline -n ci" || EXIT_CODE=1
check_item "pipeline-keyless-signer SA" "kubectl get sa pipeline-keyless-signer -n ci" || EXIT_CODE=1
check_item "tekton-triggers-sa SA" "kubectl get sa tekton-triggers-sa -n ci" || EXIT_CODE=1
check_item "registry-credentials secret" "kubectl get secret registry-credentials -n ci" || EXIT_CODE=1
check_item "registry-docker-config secret" "kubectl get secret registry-docker-config -n ci" || EXIT_CODE=1
check_item "gitea-credentials secret" "kubectl get secret gitea-credentials -n ci" || EXIT_CODE=1

echo ""
echo "  Tekton Chains & Sigstore:"
check_item "Chains controller running" "kubectl get pods -n tekton-chains -l app.kubernetes.io/name=controller --no-headers 2>/dev/null | grep -q Running" || EXIT_CODE=1
check_item "Sigstore TUF root ConfigMap" "kubectl get configmap sigstore-tuf-root -n ci" || EXIT_CODE=1

echo ""
echo "  Baseline & Attestations:"
check_item "golang-baseline-sbom ConfigMap" "kubectl get configmap golang-baseline-sbom -n ci" || EXIT_CODE=1
if [ -n "${IMAGE_DIGEST:-}" ]; then
    RECIPE_TAGS=$(curl -k -s -u "$REGISTRY_USER:$REGISTRY_PASS" \
        "https://${REGISTRY_HOST}/v2/recipe-api/tags/list" 2>/dev/null | \
        jq -r '.tags // []' 2>/dev/null || echo "[]")
    if echo "$RECIPE_TAGS" | jq -e 'index("v3.0")' > /dev/null 2>&1; then
        echo "  recipe-api:v3.0 in registry... ✓"
    else
        echo "  recipe-api:v3.0 in registry... ❌"
        EXIT_CODE=1
    fi
    check_item "PipelineRun has IMAGE_DIGEST result" "test -n '$IMAGE_DIGEST'" || EXIT_CODE=1
fi

echo ""
echo "  Release pipeline namespace:"
check_item "release-pipeline namespace" "kubectl get namespace release-pipeline" || EXIT_CODE=1
check_item "release-pipeline Pipeline" "kubectl get pipeline release-pipeline -n release-pipeline" || EXIT_CODE=1
check_item "release-pipeline EventListener" "kubectl get eventlistener release-pipeline-listener -n release-pipeline" || EXIT_CODE=1
check_item "ci-registry-credentials secret" "kubectl get secret ci-registry-credentials -n release-pipeline" || EXIT_CODE=1
check_item "ci-registry-ca-cert ConfigMap" "kubectl get configmap ci-registry-ca-cert -n release-pipeline" || EXIT_CODE=1

echo ""
echo "  Challenge 4 resources absent:"
check_item "push-build-pipeline-with-release-gate removed" "! kubectl get pipeline push-build-pipeline-with-release-gate -n ci 2>/dev/null" || EXIT_CODE=1
check_item "notify-release-verified task removed" "! kubectl get task notify-release-verified -n ci 2>/dev/null" || EXIT_CODE=1
check_item "taskrun-reader Role removed" "! kubectl get role taskrun-reader -n ci 2>/dev/null" || EXIT_CODE=1
check_item "release-pipeline-secure removed" "! kubectl get pipeline release-pipeline-secure -n release-pipeline 2>/dev/null" || EXIT_CODE=1
check_item "verify-image-policy task removed" "! kubectl get task verify-image-policy -n release-pipeline 2>/dev/null" || EXIT_CODE=1
check_item "release-pipeline-secure-listener removed" "! kubectl get eventlistener release-pipeline-secure-listener -n release-pipeline 2>/dev/null" || EXIT_CODE=1
check_item "conforma-sbom-policy ConfigMap removed" "! kubectl get configmap conforma-sbom-policy -n release-pipeline 2>/dev/null" || EXIT_CODE=1
check_item "sigstore-tuf-root in release-pipeline removed" "! kubectl get configmap sigstore-tuf-root -n release-pipeline 2>/dev/null" || EXIT_CODE=1

echo ""
echo "  Challenge 1 defense absent:"
check_item "Kyverno block-dangerous-task-commands removed" "! kubectl get clusterpolicy block-dangerous-task-commands 2>/dev/null" || EXIT_CODE=1

echo ""
echo "  Webhooks:"
FINAL_HOOKS=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" 2>/dev/null || echo "[]")
PUSH_WH_OK=$(echo "$FINAL_HOOKS" | jq '[.[] | select(.events | contains(["push"]))] | length' 2>/dev/null || echo "0")
PR_WH_OK=$(echo "$FINAL_HOOKS" | jq '[.[] | select(.events | contains(["pull_request"]))] | length' 2>/dev/null || echo "0")

if [ "$PUSH_WH_OK" -gt 0 ]; then
    echo "  Push webhook configured... ✓"
else
    echo "  Push webhook configured... ❌"
    EXIT_CODE=1
fi
if [ "$PR_WH_OK" -gt 0 ]; then
    echo "  PR webhook configured... ✓"
else
    echo "  PR webhook configured... ❌"
    EXIT_CODE=1
fi

echo ""
echo "  Gitea repository:"
BRANCH_PROTECTION=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/branch_protections" 2>/dev/null || echo "[]")
BP_COUNT=$(echo "$BRANCH_PROTECTION" | jq 'length' 2>/dev/null || echo "0")
if [ "$BP_COUNT" = "0" ]; then
    echo "  No branch protection (direct push OK)... ✓"
else
    echo "  Branch protection still active... ❌"
    EXIT_CODE=1
fi

echo ""
echo "  Pipeline state:"
REMAINING_RUNS=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")
echo "  PipelineRuns in ci: $REMAINING_RUNS"
RELEASE_RUNS=$(kubectl get pipelineruns -n release-pipeline --no-headers 2>/dev/null | wc -l || echo "0")
echo "  PipelineRuns in release-pipeline: $RELEASE_RUNS"

echo ""
echo "=========================================="
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Challenge 4 Reset Complete - Ready for Demo!"
    echo "=========================================="
    echo ""
    echo "Challenge 4: Compromised Continuous Deployment"
    echo ""
    echo "  Gitea:         $GITEA_URL/$GITEA_USER/$REPO_NAME"
    echo "  Registry:      https://${REGISTRY_HOST}"
    echo "  Image:         ${REGISTRY_HOST}/recipe-api@${IMAGE_DIGEST:-unknown}"
    echo "  PipelineRun:   ${LATEST_PR_NAME:-unknown}"
    echo ""
    echo "  Conforma/Ampel demo:       challenges/challenge4/conforma-ampel-demo.sh"
    echo "  Release verification demo: challenges/challenge4/release-verification-demo.sh"
    echo "  Monitor builds:            kubectl get pipelineruns -n ci -w"
    echo "  Monitor releases:          kubectl get pipelineruns -n release-pipeline -w"
else
    echo "❌ Some resources are missing. Check errors above."
    echo "=========================================="
    exit 1
fi
