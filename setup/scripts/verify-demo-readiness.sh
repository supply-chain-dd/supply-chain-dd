#!/bin/bash
#
# Verify Deep Dive Demo Readiness
# Checks all prerequisites for challenges 1-4
#

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ctf-cluster}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-30002}"
GITEA_URL="http://localhost:$GITEA_HTTP_PORT"
REGISTRY_NODE_PORT="${REGISTRY_NODE_PORT:-30000}"
PRODUCTION_CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-ctf-production-cluster}"
PRODUCTION_GITEA_HTTP_PORT="${PRODUCTION_GITEA_HTTP_PORT:-30004}"
PRODUCTION_GITEA_URL="http://localhost:$PRODUCTION_GITEA_HTTP_PORT"

echo "=========================================="
echo "Deep Dive Demo Readiness Check"
echo "=========================================="
echo ""

EXIT_CODE=0

# Function to check and report
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

# Switch to CTF cluster context before checking
echo "Switching to CTF cluster context (kind-$CLUSTER_NAME)..."
kubectl config use-context "kind-$CLUSTER_NAME" > /dev/null 2>&1 || true
echo ""

# 1. Cluster and Context
echo "[1] Cluster and Context"
check_item "KinD cluster exists" "kind get clusters | grep -q '$CLUSTER_NAME'" || EXIT_CODE=1
check_item "Kubectl context is correct" "[[ \$(kubectl config current-context) =~ '$CLUSTER_NAME' ]]" || EXIT_CODE=1
check_item "Cluster is responsive" "kubectl get nodes > /dev/null" || EXIT_CODE=1

# 2. Core Services
echo ""
echo "[2] Core Services"
check_item "Gitea is running" "kubectl get pods -n gitea -l app.kubernetes.io/name=gitea | grep -q Running" || EXIT_CODE=1
check_item "Gitea is accessible" "curl -f -s -o /dev/null $GITEA_URL" || EXIT_CODE=1
check_item "Registry is running" "kubectl get pods -n registry -l app=registry | grep -q Running" || EXIT_CODE=1
check_item "Registry is accessible" "curl -k -f -s -o /dev/null https://localhost:$REGISTRY_NODE_PORT/v2/_catalog" || EXIT_CODE=1
check_item "Tekton Pipelines installed" "kubectl get pods -n tekton-pipelines | grep -q Running" || EXIT_CODE=1
check_item "Tekton Triggers installed" "kubectl get deployment tekton-triggers-controller -n tekton-pipelines > /dev/null" || EXIT_CODE=1

# 3. Repository Setup
echo ""
echo "[3] Repository Setup"
GITEA_USER="ctf-admin"
GITEA_PASS="CTFSecurePass123!"
REPO_NAME="recipe-api"

check_item "recipe-api repository exists" "curl -s -u $GITEA_USER:$GITEA_PASS $GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME | jq -e '.id' > /dev/null" || EXIT_CODE=1

# 4. Challenge 1 Resources
echo ""
echo "[4] Challenge 1: PR Quality Check"
check_item "CTF namespace exists" "kubectl get namespace ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "PR pipeline exists" "kubectl get pipeline pr-quality-check-pipeline -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "git-clone task exists" "kubectl get task git-clone -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "quality-check-task exists" "kubectl get task quality-check-task -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "PR EventListener exists" "kubectl get eventlistener pr-quality-check-listener -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "PR EventListener service exists" "kubectl get svc el-pr-quality-check-listener -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "ctf-flag secret exists" "kubectl get secret ctf-flag -n ctf-challenge > /dev/null" || EXIT_CODE=1

# 5. Challenge 2 Resources
echo ""
echo "[5] Challenge 2: Container Layer Leak"
check_item "Push pipeline exists" "kubectl get pipeline push-build-pipeline -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "build-go-app task exists" "kubectl get task build-go-app -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "build-container-image task exists" "kubectl get task build-container-image -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "push-container-image task exists" "kubectl get task push-container-image -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "Push EventListener exists" "kubectl get eventlistener push-build-listener -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "Push EventListener service exists" "kubectl get svc el-push-build-listener -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "pr-pipeline-readonly SA exists" "kubectl get sa pr-pipeline-readonly -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "tekton-triggers-sa SA exists" "kubectl get sa tekton-triggers-sa -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "registry-docker-config secret exists" "kubectl get secret registry-docker-config -n ctf-challenge > /dev/null" || EXIT_CODE=1
check_item "registry-ca-cert configmap exists" "kubectl get configmap registry-ca-cert -n ctf-challenge > /dev/null" || EXIT_CODE=1

# 6. Webhooks
echo ""
echo "[6] Webhooks"
PR_WEBHOOK_COUNT=$(curl -s -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" | jq '[.[] | select(.events | contains(["pull_request"]))] | length' 2>/dev/null || echo "0")
PUSH_WEBHOOK_COUNT=$(curl -s -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks" | jq '[.[] | select(.events | contains(["push"]))] | length' 2>/dev/null || echo "0")

if [ "$PR_WEBHOOK_COUNT" -gt 0 ]; then
    echo "  PR webhook configured... ✓"
else
    echo "  PR webhook configured... ❌"
    EXIT_CODE=1
fi

if [ "$PUSH_WEBHOOK_COUNT" -gt 0 ]; then
    echo "  Push webhook configured... ✓"
else
    echo "  Push webhook configured... ❌"
    EXIT_CODE=1
fi

# 7. Images in Registry
echo ""
echo "[7] Registry Images"
REGISTRY_USER="ctf-admin"
REGISTRY_PASS="CTFRegistryPass123!"

check_item "recipe-api image exists" "curl --cacert certs/registry.crt -s -u $REGISTRY_USER:$REGISTRY_PASS https://localhost:$REGISTRY_NODE_PORT/v2/recipe-api/tags/list 2>/dev/null | jq -e '.tags' > /dev/null" || echo "  ⚠  (Will be created during demo)"

# 8. Challenge 3 Prerequisites
echo ""
echo "[8] Challenge 3: Base Image Poisoning"
check_item "golang:1.25-alpine in registry" "curl --cacert certs/registry.crt -s -u $REGISTRY_USER:$REGISTRY_PASS https://localhost:$REGISTRY_NODE_PORT/v2/golang/tags/list 2>/dev/null | grep -q '1.25-alpine'" || EXIT_CODE=1

# 9. Challenge 4 Resources
echo ""
echo "[9] Challenge 4: GitOps Pipeline Compromise"
check_item "Production cluster exists" "kind get clusters | grep -q '$PRODUCTION_CLUSTER_NAME'" || EXIT_CODE=1
check_item "Production Gitea is running" "kubectl --context kind-$PRODUCTION_CLUSTER_NAME get pods -n gitea -l app.kubernetes.io/name=gitea 2>/dev/null | grep -q Running" || EXIT_CODE=1
check_item "Production Gitea is accessible" "curl -f -s -o /dev/null $PRODUCTION_GITEA_URL" || EXIT_CODE=1
check_item "ArgoCD is running" "kubectl --context kind-$PRODUCTION_CLUSTER_NAME get pods -n argocd -l app.kubernetes.io/name=argocd-server 2>/dev/null | grep -q Running" || EXIT_CODE=1
check_item "production-manifests repo exists" "curl -s -u $GITEA_USER:$GITEA_PASS $PRODUCTION_GITEA_URL/api/v1/repos/$GITEA_USER/production-manifests | jq -e '.id' > /dev/null" || EXIT_CODE=1
check_item "ArgoCD application deployed" "kubectl --context kind-$PRODUCTION_CLUSTER_NAME get application recipe-api-production -n argocd > /dev/null" || EXIT_CODE=1
check_item "Production namespace exists" "kubectl --context kind-$PRODUCTION_CLUSTER_NAME get namespace production > /dev/null" || EXIT_CODE=1

echo ""
echo "=========================================="
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ All Prerequisites Met - Ready for Demo!"
    echo "=========================================="
    echo ""
    echo "Access Information:"
    echo "  CTF Cluster:"
    echo "    Gitea:    $GITEA_URL"
    echo "    Registry: https://localhost:$REGISTRY_NODE_PORT"
    echo "    Username: ctf-admin"
    echo "    Password: CTFSecurePass123!"
    echo ""
    echo "  Production Cluster (Challenge 4):"
    echo "    Gitea:    $PRODUCTION_GITEA_URL"
    echo "    ArgoCD:   https://localhost:30443"
    echo "    Username: ctf-admin / admin (ArgoCD)"
    echo "    Password: CTFSecurePass123! / admin123 (ArgoCD)"
    echo ""
    echo "Next Steps:"
    echo "  1. Start Challenge 1: Create a PR in Gitea"
    echo "  2. Watch pipeline: kubectl get pipelineruns -n ctf-challenge -w"
    echo "  3. Follow attack guides: challenges/challengeN/CTF-CHALLENGE-GUIDE.md"
else
    echo "❌ Some Prerequisites Missing"
    echo "=========================================="
    echo ""
    echo "Fix issues and run again: make verify-demo-readiness"
fi
echo ""

exit $EXIT_CODE
