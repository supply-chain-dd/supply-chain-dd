#!/bin/bash
#
# Reset Environment to Challenge 1 Starting State
# Brings the ci namespace to the vulnerable PR pipeline configuration,
# cleaning up artifacts from previous demo runs or other challenges.
# Safe to run multiple times (idempotent).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
GITEA_URL="http://${GITEA_HOST}"
GITEA_USER="${GITEA_USER:-sc-admin}"
GITEA_PASS="${GITEA_PASS:-SecurePass123!}"
REPO_NAME="${REPO_NAME:-recipe-api}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-change-me-in-production}"
REGISTRY_USER="${REGISTRY_USER:-sc-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-RegistryPass123!}"
CHALLENGE1_DIR="${SCRIPT_DIR}/../../challenges/challenge1"

echo "=========================================="
echo "Reset to Challenge 1 Starting State"
echo "=========================================="
echo ""

# ──────────────────────────────────────────────
# [1/8] Prerequisites
# ──────────────────────────────────────────────
echo "[1/7] Checking prerequisites..."

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

kubectl create namespace ci 2>/dev/null && echo "  ✓ Created ci namespace" || echo "  ✓ ci namespace exists"
echo ""

# ──────────────────────────────────────────────
# [2/8] Clean completed runs
# ──────────────────────────────────────────────
echo "[2/7] Cleaning completed pipeline runs and pods..."

PR_COUNT=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")
TR_COUNT=$(kubectl get taskruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")

kubectl delete pipelineruns --all -n ci --ignore-not-found 2>/dev/null || true
kubectl delete taskruns --all -n ci --ignore-not-found 2>/dev/null || true
kubectl delete pods --field-selector=status.phase!=Running -n ci --ignore-not-found 2>/dev/null || true

echo "  ✓ Cleaned $PR_COUNT PipelineRun(s), $TR_COUNT TaskRun(s)"

# Also clean release-pipeline namespace if it exists
if kubectl get namespace release-pipeline > /dev/null 2>&1; then
    kubectl delete pipelineruns --all -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete taskruns --all -n release-pipeline --ignore-not-found 2>/dev/null || true
    kubectl delete pods --field-selector=status.phase!=Running -n release-pipeline --ignore-not-found 2>/dev/null || true
    echo "  ✓ Cleaned release-pipeline namespace runs"
fi
echo ""

# ──────────────────────────────────────────────
# [3/7] Remove secure/patched resources
# ──────────────────────────────────────────────
echo "[3/7] Removing secure/patched resources..."

# Challenge 1 secure RBAC
kubectl delete sa pr-pipeline-readonly main-pipeline security-auditor -n ci --ignore-not-found 2>/dev/null || true
kubectl delete role pr-pipeline-minimal main-pipeline-privileged -n ci --ignore-not-found 2>/dev/null || true
kubectl delete rolebinding pr-pipeline-readonly-binding main-pipeline-binding -n ci --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole security-auditor --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding security-auditor-binding --ignore-not-found 2>/dev/null || true

# Challenge 1 Kyverno policies
kubectl delete clusterpolicy block-dangerous-task-commands restrict-external-git-repositories \
    restrict-tekton-pr-pipelines --ignore-not-found 2>/dev/null || true

# Network policies
kubectl delete networkpolicy ci-egress-restriction -n ci --ignore-not-found 2>/dev/null || true
kubectl delete networkpolicy tekton-pipelines-egress-restriction -n tekton-pipelines --ignore-not-found 2>/dev/null || true

echo "  ✓ Secure/patched resources removed"
echo ""

# ──────────────────────────────────────────────
# [4/7] Apply challenge 1 vulnerable resources
# ──────────────────────────────────────────────
echo "[4/7] Applying challenge 1 vulnerable resources..."

kubectl apply -f "${CHALLENGE1_DIR}/tekton/triggers/vulnerable-eventlistener.yaml"
kubectl apply -f "${CHALLENGE1_DIR}/tekton/tasks/supporting-tasks.yaml"
kubectl apply -f "${CHALLENGE1_DIR}/tekton/tasks/vulnerable-quality-check-task.yaml"
kubectl apply -f "${CHALLENGE1_DIR}/tekton/pipelines/vulnerable-pr-quality-pipeline.yaml"

kubectl create secret generic registry-credentials \
    --from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
    --from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
    --from-literal=registry-user="${REGISTRY_USER}" \
    --from-literal=registry-password="${REGISTRY_PASS}" \
    -n ci --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ Challenge 1 resources applied"
echo ""

# ──────────────────────────────────────────────
# [5/7] Fix webhook
# ──────────────────────────────────────────────
echo "[5/7] Configuring Gitea webhook..."

EXISTING_WEBHOOKS=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" 2>/dev/null || echo "[]")

# Only delete PR webhooks — preserve push and other webhooks
PR_WEBHOOK_IDS=$(echo "$EXISTING_WEBHOOKS" | \
    jq -r '.[] | select(.events | contains(["pull_request"])) | .id' 2>/dev/null || echo "")
if [ -n "$PR_WEBHOOK_IDS" ]; then
    for id in $PR_WEBHOOK_IDS; do
        curl -s -X DELETE \
            -u "$GITEA_USER:$GITEA_PASS" \
            "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks/$id" >/dev/null 2>&1
    done
    echo "  ✓ Deleted existing PR webhook(s)"
fi

PR_LISTENER_URL="http://el-pr-quality-check-listener.ci.svc.cluster.local:8080"

WEBHOOK_PAYLOAD=$(cat <<EOF
{
  "type": "gitea",
  "config": {
    "url": "$PR_LISTENER_URL",
    "content_type": "json",
    "secret": "$WEBHOOK_SECRET"
  },
  "events": ["pull_request"],
  "active": true
}
EOF
)

RESULT=$(curl -s -X POST \
    -u "$GITEA_USER:$GITEA_PASS" \
    -H "Content-Type: application/json" \
    -d "$WEBHOOK_PAYLOAD" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks")

if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
    WEBHOOK_ID=$(echo "$RESULT" | jq -r '.id')
    echo "  ✓ PR webhook created (ID: $WEBHOOK_ID)"
    echo "    Target: $PR_LISTENER_URL"
    echo "    Events: pull_request"
else
    echo "  ❌ Failed to create PR webhook"
    echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"
    exit 1
fi
echo ""

# ──────────────────────────────────────────────
# [6/7] Wait for EventListener
# ──────────────────────────────────────────────
echo "[6/7] Waiting for EventListener to be ready..."

for i in $(seq 1 30); do
    if kubectl get svc el-pr-quality-check-listener -n ci >/dev/null 2>&1; then
        echo "  ✓ EventListener service exists"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ❌ EventListener service did not appear within 60 seconds"
        exit 1
    fi
    sleep 2
done

kubectl wait --for=condition=ready pod \
    -l eventlistener=pr-quality-check-listener \
    -n ci --timeout=60s 2>/dev/null && echo "  ✓ EventListener pod ready" || \
    echo "  ⚠ EventListener pod not ready yet (may need more time)"
echo ""

# ──────────────────────────────────────────────
# [7/7] Verify
# ──────────────────────────────────────────────
echo "[7/7] Verifying challenge 1 resources..."
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

check_item "pr-quality-check-pipeline" "kubectl get pipeline pr-quality-check-pipeline -n ci" || EXIT_CODE=1
check_item "git-clone task" "kubectl get task git-clone -n ci" || EXIT_CODE=1
check_item "quality-check-task" "kubectl get task quality-check-task -n ci" || EXIT_CODE=1
check_item "build-go-app task" "kubectl get task build-go-app -n ci" || EXIT_CODE=1
check_item "print-info task" "kubectl get task print-info -n ci" || EXIT_CODE=1
check_item "print-results task" "kubectl get task print-results -n ci" || EXIT_CODE=1
check_item "PR EventListener" "kubectl get eventlistener pr-quality-check-listener -n ci" || EXIT_CODE=1
check_item "EventListener service" "kubectl get svc el-pr-quality-check-listener -n ci" || EXIT_CODE=1
check_item "TriggerBinding" "kubectl get triggerbinding pr-quality-binding -n ci" || EXIT_CODE=1
check_item "TriggerTemplate" "kubectl get triggertemplate pr-quality-template -n ci" || EXIT_CODE=1
check_item "tekton-triggers-sa" "kubectl get sa tekton-triggers-sa -n ci" || EXIT_CODE=1
check_item "taskrun-role (vulnerable RBAC)" "kubectl get role taskrun-role -n ci" || EXIT_CODE=1
check_item "registry-credentials secret" "kubectl get secret registry-credentials -n ci" || EXIT_CODE=1
check_item "github-webhook-secret" "kubectl get secret github-webhook-secret -n ci" || EXIT_CODE=1

echo ""
echo "  Secure resources absent:"
check_item "pr-pipeline-readonly removed" "! kubectl get sa pr-pipeline-readonly -n ci 2>/dev/null" || EXIT_CODE=1
check_item "Kyverno policies removed" "! kubectl get clusterpolicy block-dangerous-task-commands 2>/dev/null" || EXIT_CODE=1
check_item "Network policies removed" "! kubectl get networkpolicy ci-egress-restriction -n ci 2>/dev/null" || EXIT_CODE=1

echo ""
echo "  Webhooks:"
PR_WEBHOOK_COUNT=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" | \
    jq '[.[] | select(.events | contains(["pull_request"]))] | length' 2>/dev/null || echo "0")

if [ "$PR_WEBHOOK_COUNT" -gt 0 ]; then
    echo "  PR webhook configured... ✓"
else
    echo "  PR webhook configured... ❌"
    EXIT_CODE=1
fi

echo ""
echo "  Clean state:"
REMAINING_RUNS=$(kubectl get pipelineruns -n ci --no-headers 2>/dev/null | wc -l || echo "0")
echo "  PipelineRuns remaining: $REMAINING_RUNS"

echo ""
echo "=========================================="
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Challenge 1 Reset Complete - Ready for Demo!"
    echo "=========================================="
    echo ""
    echo "Challenge 1: Tekton Token Theft (Pwn Request)"
    echo ""
    echo "  Gitea:    $GITEA_URL"
    echo "  Username: $GITEA_USER"
    echo "  Password: $GITEA_PASS"
    echo ""
    echo "  Attack guide: challenges/challenge1/ATTACK-GUIDE.md"
    echo "  Monitor:      kubectl get pipelineruns -n ci -w"
else
    echo "❌ Some resources are missing. Check errors above."
    echo "=========================================="
    exit 1
fi
