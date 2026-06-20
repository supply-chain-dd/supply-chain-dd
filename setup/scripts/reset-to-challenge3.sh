#!/bin/bash
#
# Reset Environment to Challenge 3 Starting State
# Brings the environment to the "Base Image Poisoning" configuration:
#   - Challenge 2 resources (push-build-pipeline, tasks, triggers) intact
#   - push-build-pipeline-with-chains deployed (challenge 3 vulnerable pipeline)
#   - Legitimate golang:1.25-alpine and alpine:3.20 in registry (clean, not poisoned)
#   - recipe-api:v1.0 in registry (vulnerable single-stage build)
#   - Gitea recipe-api repo has challenge 2 fixed Dockerfile (multi-stage, tag-based FROM, no digest pinning)
#   - No branch protection on main
#   - Challenge 3 defense artifacts removed (secure pipeline, kyverno policies, baseline jobs)
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

echo "=========================================="
echo "Reset to Challenge 3 Starting State"
echo "=========================================="
echo ""

# ──────────────────────────────────────────────
# [1/12] Prerequisites
# ──────────────────────────────────────────────
echo "[1/12] Checking prerequisites..."

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

kubectl get namespace tekton-chains > /dev/null 2>&1 || {
    echo "  ❌ Tekton Chains not installed"
    echo "     Run: make setup-tektonchains"
    exit 1
}
echo "  ✓ Tekton Chains namespace exists"

kubectl create namespace ci 2>/dev/null && echo "  ✓ Created ci namespace" || echo "  ✓ ci namespace exists"
echo ""

# ──────────────────────────────────────────────
# [2/12] Clean completed runs
# ──────────────────────────────────────────────
echo "[2/12] Cleaning completed pipeline runs and pods..."

PR_COUNT=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")
TR_COUNT=$(kubectl get taskruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")

# Strip Tekton Chains finalizers (they block deletion indefinitely)
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
# [3/12] Remove challenge 1 secure resources
# ──────────────────────────────────────────────
echo "[3/12] Removing challenge 1 secure/defense resources..."

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
# [4/12] Remove challenge 2 patched resources
# ──────────────────────────────────────────────
echo "[4/12] Removing challenge 2 patched/defense resources..."

kubectl delete pipeline push-build-pipeline-secure -n ci --ignore-not-found 2>/dev/null || true

echo "  ✓ Challenge 2 patched resources removed"
echo ""

# ──────────────────────────────────────────────
# [5/12] Remove challenge 3 defense resources
# ──────────────────────────────────────────────
echo "[5/12] Removing challenge 3 defense resources..."

# Secure pipeline and tasks
kubectl delete pipeline push-build-pipeline-with-chains-secure -n ci --ignore-not-found 2>/dev/null || true
kubectl delete task verify-base-image -n ci --ignore-not-found 2>/dev/null || true
kubectl delete task attest-sbom-keyless -n ci --ignore-not-found 2>/dev/null || true

# Kyverno policies from challenge 3
kubectl delete clusterpolicy require-image-digest require-sbom-attestation --ignore-not-found 2>/dev/null || true

# Baseline SBOM ConfigMap (will be regenerated during defense demo)
kubectl delete configmap golang-baseline-sbom -n ci --ignore-not-found 2>/dev/null || true

# Cleanup leftover jobs from defense demo
kubectl delete job generate-baseline-from-hub generate-sbom-baseline -n ci --ignore-not-found 2>/dev/null || true

echo "  ✓ Challenge 3 defense resources removed"
echo ""

# ──────────────────────────────────────────────
# [6/12] Apply challenge 2 baseline resources
# ──────────────────────────────────────────────
echo "[6/12] Applying challenge 2 baseline Tekton resources..."

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

# Restore trigger template to reference push-build-pipeline (undo challenge 2 defense-demo patch)
kubectl patch triggertemplate push-build-template -n ci --type=json \
    -p='[{"op":"replace","path":"/spec/resourcetemplates/0/spec/pipelineRef/name","value":"push-build-pipeline"},{"op":"replace","path":"/spec/params/6/default","value":"v1.0"}]' 2>/dev/null || true

echo "  ✓ Challenge 2 baseline resources applied"
echo ""

# ──────────────────────────────────────────────
# [7/12] Apply challenge 3 vulnerable pipeline
# ──────────────────────────────────────────────
echo "[7/12] Applying challenge 3 Tekton resources (vulnerable pipeline)..."

kubectl apply -f "${CHALLENGE3_DIR}/tekton/tasks/"
kubectl apply -f "${CHALLENGE3_DIR}/tekton/pipelines/"

echo "  ✓ push-build-pipeline-with-chains deployed"
echo ""

# ──────────────────────────────────────────────
# [8/12] Ensure Tekton Chains is running
# ──────────────────────────────────────────────
echo "[8/12] Ensuring Tekton Chains controller is running..."

CURRENT_REPLICAS=$(kubectl get deployment tekton-chains-controller -n tekton-chains -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "$CURRENT_REPLICAS" = "0" ]; then
    kubectl scale deployment tekton-chains-controller --replicas=1 -n tekton-chains
    echo "  ✓ Tekton Chains controller scaled back up"
else
    echo "  ✓ Tekton Chains controller already running"
fi
echo ""

# ──────────────────────────────────────────────
# [9/12] Restore Gitea repository
# ──────────────────────────────────────────────
echo "[9/12] Restoring Gitea recipe-api to end-of-challenge-2 state..."

# Remove branch protection on main (defense-demo may add it)
curl -s -X DELETE \
    -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/branch_protections/main" >/dev/null 2>&1 || true
echo "  ✓ Branch protection removed from main"

# Delete the fix branch if the defense-demo created it
curl -s -X DELETE \
    -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/branches/fix/pin-base-image-digest" >/dev/null 2>&1 || true
echo "  ✓ Cleaned up defense-demo branches"

# Re-seed the repository — restores base git history (3 original commits)
"${SCRIPT_DIR}/seed-victim-repo.sh"
echo "  ✓ Victim repository re-seeded with base history"

# Apply challenge 2 defense fix on top: multi-stage Dockerfile + .dockerignore
# This is the state the repo is in at the end of challenge 2's defense-demo.
# The multi-stage Dockerfile still uses tag-based FROM (not digest-pinned),
# which is the vulnerability challenge 3 exploits.
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
cp "${CHALLENGE2_DIR}/tekton-patched/Dockerfile" "${REPO_WORK_DIR}/${REPO_NAME}/Dockerfile"
cp "${CHALLENGE2_DIR}/tekton-patched/.dockerignore" "${REPO_WORK_DIR}/${REPO_NAME}/.dockerignore"

cd "${REPO_WORK_DIR}/${REPO_NAME}"
git add Dockerfile .dockerignore
GIT_CONFIG_GLOBAL="$GIT_CONFIG_FILE" git commit -m 'fix: multi-stage build + .dockerignore' 2>/dev/null
git remote set-url origin "http://${GITEA_USER}:SecurePass123%21@${GITEA_HOST}/${GITEA_USER}/${REPO_NAME}.git"
GIT_CONFIG_GLOBAL="$GIT_CONFIG_FILE" git push origin main 2>/dev/null
cd "$PROJECT_ROOT"

rm -rf "$REPO_WORK_DIR" "$GIT_CRED_FILE" "$GIT_CONFIG_FILE"
echo "  ✓ Applied challenge 2 fix (multi-stage Dockerfile + .dockerignore)"
echo ""

# ──────────────────────────────────────────────
# [10/12] Restore legitimate base image in registry
# ──────────────────────────────────────────────
echo "[10/12] Restoring legitimate base image in registry..."

# Re-seed the clean golang:1.25-alpine (overwrites any poisoned version)
echo "  Pulling clean golang:1.25-alpine from Docker Hub..."
$CONTAINER_RUNTIME pull golang:1.25-alpine 2>/dev/null || true
$CONTAINER_RUNTIME tag golang:1.25-alpine "${REGISTRY_HOST}/golang:1.25-alpine"
$CONTAINER_RUNTIME login "${REGISTRY_HOST}" \
    -u "$REGISTRY_USER" -p "$REGISTRY_PASS" 2>/dev/null || true
$CONTAINER_RUNTIME push "${REGISTRY_HOST}/golang:1.25-alpine"
echo "  ✓ Clean golang:1.25-alpine pushed to registry"

# Also ensure alpine:3.20 exists (used by multi-stage builds)
echo "  Pulling alpine:3.20..."
$CONTAINER_RUNTIME pull alpine:3.20 2>/dev/null || true
$CONTAINER_RUNTIME tag alpine:3.20 "${REGISTRY_HOST}/alpine:3.20"
$CONTAINER_RUNTIME push "${REGISTRY_HOST}/alpine:3.20"
echo "  ✓ Clean alpine:3.20 pushed to registry"

# Ensure recipe-api:v1.0 exists
IMAGE_EXISTS=$(curl -k -s \
    -u "$REGISTRY_USER:$REGISTRY_PASS" \
    "https://${REGISTRY_HOST}/v2/recipe-api/tags/list" 2>/dev/null | \
    jq -r '.tags // [] | index("v1.0")' 2>/dev/null || echo "null")

if [ "$IMAGE_EXISTS" != "null" ] && [ "$IMAGE_EXISTS" != "" ]; then
    echo "  ✓ recipe-api:v1.0 already exists in registry"
else
    echo "  Building vulnerable recipe-api:v1.0..."
    rm -rf /tmp/recipe-api-build
    cp -r "${PROJECT_ROOT}/challenges/victim-repo-sample" /tmp/recipe-api-build
    if [ -d /tmp/recipe-api-build/_git ]; then
        mv /tmp/recipe-api-build/_git /tmp/recipe-api-build/.git
    fi
    sed -i "s|registry.registry.svc.cluster.local:5000|${REGISTRY_DOMAIN}:${GATEWAY_HTTPS_PORT}|g" /tmp/recipe-api-build/Dockerfile

    cd /tmp/recipe-api-build
    $CONTAINER_RUNTIME build -t "${REGISTRY_HOST}/recipe-api:v1.0" -f Dockerfile . 2>&1 | grep -E "(STEP|Successfully|Error)" || true
    cd "$PROJECT_ROOT"

    $CONTAINER_RUNTIME push "${REGISTRY_HOST}/recipe-api:v1.0"
    rm -rf /tmp/recipe-api-build
    echo "  ✓ Vulnerable recipe-api:v1.0 built and pushed"
fi
echo ""

# ──────────────────────────────────────────────
# [11/12] Fix webhooks
# ──────────────────────────────────────────────
echo "[11/12] Configuring Gitea webhooks..."

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

# -- PR webhook (for challenge 1 compatibility) --
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
# [12/12] Verify
# ──────────────────────────────────────────────
echo "[12/12] Verifying challenge 3 resources..."
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
check_item "Push EventListener service" "kubectl get svc el-push-build-listener -n ci" || EXIT_CODE=1
check_item "PR EventListener" "kubectl get eventlistener pr-quality-check-listener -n ci" || EXIT_CODE=1

echo ""
echo "  Challenge 3 pipeline:"
check_item "push-build-pipeline-with-chains" "kubectl get pipeline push-build-pipeline-with-chains -n ci" || EXIT_CODE=1
check_item "push-container-image-with-chains task" "kubectl get task push-container-image-with-chains -n ci" || EXIT_CODE=1
check_item "generate-sbom task" "kubectl get task generate-sbom -n ci" || EXIT_CODE=1
check_item "scan-image task" "kubectl get task scan-image -n ci" || EXIT_CODE=1
check_item "verify-source-provenance task" "kubectl get task verify-source-provenance -n ci" || EXIT_CODE=1
check_item "create-source-vsa task" "kubectl get task create-source-vsa -n ci" || EXIT_CODE=1
check_item "sign-image-keyless task" "kubectl get task sign-image-keyless -n ci" || EXIT_CODE=1

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
echo "  Defense artifacts absent:"
check_item "push-build-pipeline-with-chains-secure removed" "! kubectl get pipeline push-build-pipeline-with-chains-secure -n ci 2>/dev/null" || EXIT_CODE=1
check_item "verify-base-image task removed" "! kubectl get task verify-base-image -n ci 2>/dev/null" || EXIT_CODE=1
check_item "golang-baseline-sbom configmap removed" "! kubectl get configmap golang-baseline-sbom -n ci 2>/dev/null" || EXIT_CODE=1
check_item "Kyverno require-image-digest removed" "! kubectl get clusterpolicy require-image-digest 2>/dev/null" || EXIT_CODE=1
check_item "Kyverno require-sbom-attestation removed" "! kubectl get clusterpolicy require-sbom-attestation 2>/dev/null" || EXIT_CODE=1
check_item "Challenge 1 Kyverno policies removed" "! kubectl get clusterpolicy block-dangerous-task-commands 2>/dev/null" || EXIT_CODE=1

echo ""
echo "  Registry images:"
GOLANG_EXISTS=$(curl -k -s -u "$REGISTRY_USER:$REGISTRY_PASS" \
    "https://${REGISTRY_HOST}/v2/golang/tags/list" 2>/dev/null | \
    jq -r '.tags // []' 2>/dev/null || echo "[]")
if echo "$GOLANG_EXISTS" | jq -e 'index("1.25-alpine")' > /dev/null 2>&1; then
    echo "  golang:1.25-alpine in registry... ✓"
else
    echo "  golang:1.25-alpine in registry... ❌"
    EXIT_CODE=1
fi

ALPINE_EXISTS=$(curl -k -s -u "$REGISTRY_USER:$REGISTRY_PASS" \
    "https://${REGISTRY_HOST}/v2/alpine/tags/list" 2>/dev/null | \
    jq -r '.tags // []' 2>/dev/null || echo "[]")
if echo "$ALPINE_EXISTS" | jq -e 'index("3.20")' > /dev/null 2>&1; then
    echo "  alpine:3.20 in registry... ✓"
else
    echo "  alpine:3.20 in registry... ❌"
    EXIT_CODE=1
fi

RECIPE_EXISTS=$(curl -k -s -u "$REGISTRY_USER:$REGISTRY_PASS" \
    "https://${REGISTRY_HOST}/v2/recipe-api/tags/list" 2>/dev/null | \
    jq -r '.tags // []' 2>/dev/null || echo "[]")
if echo "$RECIPE_EXISTS" | jq -e 'index("v1.0")' > /dev/null 2>&1; then
    echo "  recipe-api:v1.0 in registry... ✓"
else
    echo "  recipe-api:v1.0 in registry... ❌"
    EXIT_CODE=1
fi

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
echo "  Clean state:"
REMAINING_RUNS=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")
echo "  PipelineRuns remaining: $REMAINING_RUNS"

echo ""
echo "=========================================="
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Challenge 3 Reset Complete - Ready for Demo!"
    echo "=========================================="
    echo ""
    echo "Challenge 3: Base Image Poisoning"
    echo ""
    echo "  Gitea:    $GITEA_URL/$GITEA_USER/$REPO_NAME"
    echo "  Registry: https://${REGISTRY_HOST}"
    echo "  Username: $GITEA_USER"
    echo "  Password: $GITEA_PASS"
    echo ""
    echo "  Attack guide:       challenges/challenge3/ATTACK-GUIDE.md"
    echo "  SBOM comparison:    challenges/challenge3/sbom-comparison-demo.sh"
    echo "  Defense demo:       challenges/challenge3/defense-demo.sh"
    echo "  Monitor builds:     kubectl get pipelineruns -n ci -w"
else
    echo "❌ Some resources are missing. Check errors above."
    echo "=========================================="
    exit 1
fi
