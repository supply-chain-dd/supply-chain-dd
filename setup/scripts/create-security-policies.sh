#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================"
echo "Security Policy Setup Script"
echo -e "========================================${NC}"
echo ""

# Get the script directory (setup/scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root (two levels up from scripts/)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SECURITY_DIR="${PROJECT_ROOT}/security"

echo -e "${GREEN}✓${NC} Project root: ${PROJECT_ROOT}"
echo -e "${GREEN}✓${NC} Security policies directory: ${SECURITY_DIR}"
echo ""

# ============================================================
# Step 1: Label namespaces for NetworkPolicy selectors
# ============================================================

echo -e "${BLUE}[1/4] Labeling namespaces...${NC}"
echo "------------------------------------------------"

# Label kube-system for DNS resolution
kubectl label namespace kube-system kubernetes.io/metadata.name=kube-system --overwrite 2>/dev/null || true
echo -e "${GREEN}✓${NC} Labeled kube-system namespace"

# Label gitea namespace
kubectl get namespace gitea >/dev/null 2>&1 && {
    kubectl label namespace gitea kubernetes.io/metadata.name=gitea --overwrite
    echo -e "${GREEN}✓${NC} Labeled gitea namespace"
} || echo -e "${YELLOW}⚠${NC} Gitea namespace not found (will be labeled when created)"

# Label ctf-challenge namespace
kubectl get namespace ctf-challenge >/dev/null 2>&1 && {
    kubectl label namespace ctf-challenge kubernetes.io/metadata.name=ctf-challenge --overwrite
    echo -e "${GREEN}✓${NC} Labeled ctf-challenge namespace"
} || echo -e "${YELLOW}⚠${NC} CTF challenge namespace not found (will be labeled when created)"

# Label tekton-pipelines namespace
kubectl get namespace tekton-pipelines >/dev/null 2>&1 && {
    kubectl label namespace tekton-pipelines kubernetes.io/metadata.name=tekton-pipelines --overwrite
    echo -e "${GREEN}✓${NC} Labeled tekton-pipelines namespace"
} || echo -e "${YELLOW}⚠${NC} Tekton pipelines namespace not found (will be labeled when created)"

echo ""

# ============================================================
# Step 2: Apply Kyverno Policies
# ============================================================

echo -e "${BLUE}[2/4] Applying Kyverno policies...${NC}"
echo "------------------------------------------------"

if [ -d "${SECURITY_DIR}/kyverno-policies" ]; then
    # Check if Kyverno is installed
    if kubectl get namespace kyverno >/dev/null 2>&1; then
        # Wait for Kyverno to be ready
        echo "Waiting for Kyverno to be ready..."
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=60s 2>/dev/null || {
            echo -e "${YELLOW}⚠${NC} Kyverno pods not ready yet, policies may not be enforced immediately"
        }

        echo "Applying Kyverno ClusterPolicies..."
        kubectl apply -f "${SECURITY_DIR}/kyverno-policies/"
        echo -e "${GREEN}✓${NC} Kyverno policies applied"

        # List installed policies
        echo ""
        echo "Installed policies:"
        kubectl get clusterpolicy -o custom-columns=NAME:.metadata.name,BACKGROUND:.spec.background,ACTION:.spec.validationFailureAction
    else
        echo -e "${YELLOW}⚠${NC} Kyverno not installed. Install with: make setup-kyverno"
        echo "   Policies will be available in: ${SECURITY_DIR}/kyverno-policies/"
    fi
else
    echo -e "${RED}✗${NC} Kyverno policies directory not found: ${SECURITY_DIR}/kyverno-policies/"
    exit 1
fi

echo ""

# ============================================================
# Step 3: Apply Network Policies
# ============================================================

echo -e "${BLUE}[3/4] Applying Network Policies...${NC}"
echo "------------------------------------------------"

if [ -d "${SECURITY_DIR}/network-policies" ]; then
    # Apply to tekton-pipelines namespace if it exists
    if kubectl get namespace tekton-pipelines >/dev/null 2>&1; then
        echo "Applying Network Policies to tekton-pipelines namespace..."
        kubectl apply -f "${SECURITY_DIR}/network-policies/tekton-egress-restriction.yaml"
        echo -e "${GREEN}✓${NC} Network policies applied to tekton-pipelines"
    else
        echo -e "${YELLOW}⚠${NC} tekton-pipelines namespace not found (run: make setup-tekton)"
    fi

    # Apply to ctf-challenge namespace if it exists
    if kubectl get namespace ctf-challenge >/dev/null 2>&1; then
        echo "Network policies for ctf-challenge are in the same file"
        echo -e "${GREEN}✓${NC} Network policies configured for ctf-challenge"
    else
        echo -e "${YELLOW}⚠${NC} ctf-challenge namespace not found (run: make setup-ctf-challenge)"
    fi

    # List installed network policies
    echo ""
    echo "Installed NetworkPolicies:"
    kubectl get networkpolicy --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,POD-SELECTOR:.spec.podSelector 2>/dev/null || echo "  None found yet"
else
    echo -e "${RED}✗${NC} Network policies directory not found: ${SECURITY_DIR}/network-policies/"
    exit 1
fi

echo ""

# ============================================================
# Step 4: Apply RBAC Configurations
# ============================================================

echo -e "${BLUE}[4/4] Applying RBAC configurations...${NC}"
echo "------------------------------------------------"

if [ -f "${SECURITY_DIR}/rbac/minimal-serviceaccounts.yaml" ]; then
    # Create ctf-challenge namespace if it doesn't exist
    kubectl create namespace ctf-challenge 2>/dev/null || true

    # Apply RBAC configs
    kubectl apply -f "${SECURITY_DIR}/rbac/minimal-serviceaccounts.yaml"
    echo -e "${GREEN}✓${NC} RBAC configurations applied"

    # Show created ServiceAccounts
    echo ""
    echo "ServiceAccounts in ctf-challenge namespace:"
    kubectl get sa -n ctf-challenge -o custom-columns=NAME:.metadata.name,SECRETS:.secrets[*].name 2>/dev/null || echo "  None found"

    echo ""
    echo "Roles and RoleBindings:"
    kubectl get role,rolebinding -n ctf-challenge -o custom-columns=KIND:.kind,NAME:.metadata.name 2>/dev/null || echo "  None found"
else
    echo -e "${RED}✗${NC} RBAC configuration file not found: ${SECURITY_DIR}/rbac/minimal-serviceaccounts.yaml"
    exit 1
fi

echo ""

# ============================================================
# Summary
# ============================================================

echo -e "${GREEN}========================================"
echo "✓ Security Policy Setup Complete"
echo -e "========================================${NC}"
echo ""
echo "Summary:"
echo "  ✓ Namespaces labeled for NetworkPolicy selectors"
echo "  ✓ Kyverno policies applied (if Kyverno is installed)"
echo "  ✓ Network policies applied (egress restrictions)"
echo "  ✓ RBAC configurations applied (least privilege ServiceAccounts)"
echo ""
echo "Next steps:"
echo "  1. Verify security setup: make verify-security"
echo "  2. Run security scans: make security-scan"
echo "  3. Test the defenses: see security/README.md"
echo ""
echo "ServiceAccounts available:"
echo "  • pr-pipeline-readonly   - For untrusted PR pipelines (NO secret access)"
echo "  • main-pipeline          - For trusted main branch (limited secret access)"
echo "  • security-auditor       - For monitoring tools (read-only)"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC} Update your PipelineRun manifests to use 'pr-pipeline-readonly'"
echo "  Example:"
echo "    spec:"
echo "      serviceAccountName: pr-pipeline-readonly"
echo ""
