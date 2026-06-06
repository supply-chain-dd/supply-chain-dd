#!/bin/bash
#
# Reset Environment to Challenge 2 Starting State
# Brings the environment to the vulnerable "Container Layer Leak" configuration:
#   - push-build-pipeline (vulnerable, single-stage Dockerfile)
#   - recipe-api:v1.0 in registry (with .git baked into layers)
#   - Gitea recipe-api repo has vulnerable Dockerfile, no .dockerignore
#   - Main branch can be pushed to directly (no branch protection)
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

echo "=========================================="
echo "Reset to Challenge 2 Starting State"
echo "=========================================="
echo ""

# ──────────────────────────────────────────────
# [1/10] Prerequisites
# ──────────────────────────────────────────────
echo "[1/10] Checking prerequisites..."

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
    echo "     Set CONTAINER_RUNTIME=podman or CONTAINER_RUNTIME=docker"
    exit 1
fi
echo "  ✓ Container runtime: $CONTAINER_RUNTIME"

kubectl create namespace ci 2>/dev/null && echo "  ✓ Created ci namespace" || echo "  ✓ ci namespace exists"
echo ""

# ──────────────────────────────────────────────
# [2/10] Clean completed runs
# ──────────────────────────────────────────────
echo "[2/10] Cleaning completed pipeline runs and pods..."

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
# [3/10] Remove challenge 1 secure resources
# ──────────────────────────────────────────────
echo "[3/10] Removing challenge 1 secure/defense resources..."

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
# [4/10] Remove challenge 2 patched resources
# ──────────────────────────────────────────────
echo "[4/10] Removing challenge 2 patched/defense resources..."

kubectl delete pipeline push-build-pipeline-secure -n ci --ignore-not-found 2>/dev/null || true
echo "  ✓ push-build-pipeline-secure removed"

echo ""

# ──────────────────────────────────────────────
# [5/10] Apply challenge 2 vulnerable resources
# ──────────────────────────────────────────────
echo "[5/10] Applying challenge 2 vulnerable Tekton resources..."

kubectl apply -f "${CHALLENGE2_DIR}/tekton/gitea-credentials.yaml"
kubectl apply -f "${CHALLENGE2_DIR}/tekton/serviceaccounts.yaml"
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

# Restore trigger template to reference push-build-pipeline (undo defense-demo patch)
kubectl patch triggertemplate push-build-template -n ci --type=json \
    -p='[{"op":"replace","path":"/spec/resourcetemplates/0/spec/pipelineRef/name","value":"push-build-pipeline"},{"op":"replace","path":"/spec/params/6/default","value":"v1.0"}]' 2>/dev/null || true

echo "  ✓ Challenge 2 vulnerable resources applied"
echo "  ✓ TriggerTemplate restored to push-build-pipeline (v1.0)"
echo ""

# ──────────────────────────────────────────────
# [6/10] Restore Tekton Chains controller
# ──────────────────────────────────────────────
echo "[6/10] Ensuring Tekton Chains controller is running..."

if kubectl get namespace tekton-chains > /dev/null 2>&1; then
    CURRENT_REPLICAS=$(kubectl get deployment tekton-chains-controller -n tekton-chains -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$CURRENT_REPLICAS" = "0" ]; then
        kubectl scale deployment tekton-chains-controller --replicas=1 -n tekton-chains
        echo "  ✓ Tekton Chains controller scaled back up"
    else
        echo "  ✓ Tekton Chains controller already running"
    fi
else
    echo "  - Tekton Chains not installed (skipping)"
fi
echo ""

# ──────────────────────────────────────────────
# [7/10] Restore Gitea repository
# ──────────────────────────────────────────────
echo "[7/10] Restoring Gitea recipe-api to vulnerable state..."

# Remove branch protection on main (defense-demo adds it)
curl -s -X DELETE \
    -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/branch_protections/main" >/dev/null 2>&1 || true
echo "  ✓ Branch protection removed from main"

# Re-seed the repository — restores vulnerable Dockerfile, git history with secrets
"${SCRIPT_DIR}/seed-victim-repo.sh"
echo "  ✓ Victim repository re-seeded with vulnerable source"
echo ""

# ──────────────────────────────────────────────
# [8/10] Rebuild and push vulnerable container image
# ──────────────────────────────────────────────
echo "[8/10] Rebuilding vulnerable recipe-api:v1.0 image..."

IMAGE_EXISTS=$(curl -k -s \
    -u "$REGISTRY_USER:$REGISTRY_PASS" \
    "https://${REGISTRY_HOST}/v2/recipe-api/tags/list" 2>/dev/null | \
    jq -r '.tags // [] | index("v1.0")' 2>/dev/null || echo "null")

if [ "$IMAGE_EXISTS" != "null" ] && [ "$IMAGE_EXISTS" != "" ]; then
    echo "  ✓ recipe-api:v1.0 already exists in registry (skipping rebuild)"
else
    echo "  Building image with leaked git history..."
    rm -rf /tmp/recipe-api-build
    cp -r "${PROJECT_ROOT}/challenges/victim-repo-sample" /tmp/recipe-api-build
    if [ -d /tmp/recipe-api-build/_git ]; then
        mv /tmp/recipe-api-build/_git /tmp/recipe-api-build/.git
    fi
    sed -i "s|registry.registry.svc.cluster.local:5000|${REGISTRY_DOMAIN}:${GATEWAY_HTTPS_PORT}|g" /tmp/recipe-api-build/Dockerfile

    cd /tmp/recipe-api-build
    $CONTAINER_RUNTIME build -t "${REGISTRY_HOST}/recipe-api:v1.0" -f Dockerfile . 2>&1 | grep -E "(STEP|Successfully|Error)" || true
    cd "$PROJECT_ROOT"

    echo "  Pushing to registry..."
    $CONTAINER_RUNTIME login "${REGISTRY_HOST}" \
        -u "$REGISTRY_USER" -p "$REGISTRY_PASS" 2>/dev/null || true
    $CONTAINER_RUNTIME push "${REGISTRY_HOST}/recipe-api:v1.0"

    rm -rf /tmp/recipe-api-build
    echo "  ✓ Vulnerable recipe-api:v1.0 built and pushed"
fi
echo ""

# ──────────────────────────────────────────────
# [9/10] Fix webhooks
# ──────────────────────────────────────────────
echo "[9/10] Configuring Gitea webhooks..."

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
    echo "  ✓ Deleted existing push webhook(s)"
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
# Re-read webhooks after push creation
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
# [10/10] Verify
# ──────────────────────────────────────────────
echo "[10/10] Verifying challenge 2 resources..."
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

echo "  Pipelines & Tasks:"
check_item "push-build-pipeline" "kubectl get pipeline push-build-pipeline -n ci" || EXIT_CODE=1
check_item "push-build-pipeline-keyless" "kubectl get pipeline push-build-pipeline-keyless -n ci" || EXIT_CODE=1
check_item "git-clone task" "kubectl get task git-clone -n ci" || EXIT_CODE=1
check_item "build-go-app task" "kubectl get task build-go-app -n ci" || EXIT_CODE=1
check_item "quality-check-task" "kubectl get task quality-check-task -n ci" || EXIT_CODE=1
check_item "build-container-image task" "kubectl get task build-container-image -n ci" || EXIT_CODE=1
check_item "push-container-image task" "kubectl get task push-container-image -n ci" || EXIT_CODE=1

echo ""
echo "  Triggers:"
check_item "Push EventListener" "kubectl get eventlistener push-build-listener -n ci" || EXIT_CODE=1
check_item "Push EventListener service" "kubectl get svc el-push-build-listener -n ci" || EXIT_CODE=1
check_item "PR EventListener" "kubectl get eventlistener pr-quality-check-listener -n ci" || EXIT_CODE=1
check_item "PR EventListener service" "kubectl get svc el-pr-quality-check-listener -n ci" || EXIT_CODE=1
check_item "TriggerBinding (push)" "kubectl get triggerbinding push-build-binding -n ci" || EXIT_CODE=1
check_item "TriggerTemplate (push)" "kubectl get triggertemplate push-build-template -n ci" || EXIT_CODE=1

echo ""
echo "  RBAC & Secrets:"
check_item "challenge2-pipeline SA" "kubectl get sa challenge2-pipeline -n ci" || EXIT_CODE=1
check_item "tekton-triggers-sa SA" "kubectl get sa tekton-triggers-sa -n ci" || EXIT_CODE=1
check_item "registry-credentials secret" "kubectl get secret registry-credentials -n ci" || EXIT_CODE=1
check_item "registry-docker-config secret" "kubectl get secret registry-docker-config -n ci" || EXIT_CODE=1
check_item "gitea-credentials secret" "kubectl get secret gitea-credentials -n ci" || EXIT_CODE=1
check_item "taskrun-role (vulnerable RBAC)" "kubectl get role taskrun-role -n ci" || EXIT_CODE=1

echo ""
echo "  Defense artifacts absent:"
check_item "push-build-pipeline-secure removed" "! kubectl get pipeline push-build-pipeline-secure -n ci 2>/dev/null" || EXIT_CODE=1
check_item "Kyverno policies removed" "! kubectl get clusterpolicy block-dangerous-task-commands 2>/dev/null" || EXIT_CODE=1
check_item "Network policies removed" "! kubectl get networkpolicy ci-egress-restriction -n ci 2>/dev/null" || EXIT_CODE=1

echo ""
echo "  TriggerTemplate target:"
TEMPLATE_PIPELINE=$(kubectl get triggertemplate push-build-template -n ci -o jsonpath='{.spec.resourcetemplates[0].spec.pipelineRef.name}' 2>/dev/null || echo "unknown")
TEMPLATE_TAG=$(kubectl get triggertemplate push-build-template -n ci -o jsonpath='{.spec.params[6].default}' 2>/dev/null || echo "unknown")
if [ "$TEMPLATE_PIPELINE" = "push-build-pipeline" ]; then
    echo "  TriggerTemplate → push-build-pipeline... ✓"
else
    echo "  TriggerTemplate → $TEMPLATE_PIPELINE (expected push-build-pipeline)... ❌"
    EXIT_CODE=1
fi
if [ "$TEMPLATE_TAG" = "v1.0" ]; then
    echo "  TriggerTemplate image-tag default → v1.0... ✓"
else
    echo "  TriggerTemplate image-tag default → $TEMPLATE_TAG (expected v1.0)... ❌"
    EXIT_CODE=1
fi

echo ""
echo "  Registry:"
IMAGE_CHECK=$(curl -k -s \
    -u "$REGISTRY_USER:$REGISTRY_PASS" \
    "https://${REGISTRY_HOST}/v2/recipe-api/tags/list" 2>/dev/null | \
    jq -r '.tags // []' 2>/dev/null || echo "[]")
if echo "$IMAGE_CHECK" | jq -e 'index("v1.0")' > /dev/null 2>&1; then
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
    echo "✓ Challenge 2 Reset Complete - Ready for Demo!"
    echo "=========================================="
    echo ""
    echo "Challenge 2: Container Image Layer Leak"
    echo ""
    echo "  Gitea:    $GITEA_URL/$GITEA_USER/$REPO_NAME"
    echo "  Registry: https://${REGISTRY_HOST}"
    echo "  Username: $GITEA_USER"
    echo "  Password: $GITEA_PASS"
    echo ""
    echo "  Attack guide:   challenges/challenge2/ATTACK-GUIDE.md"
    echo "  Defense demo:   challenges/challenge2/defense-demo.sh"
    echo "  Monitor builds: kubectl get pipelineruns -n ci -w"
else
    echo "❌ Some resources are missing. Check errors above."
    echo "=========================================="
    exit 1
fi
