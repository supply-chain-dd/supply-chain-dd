#!/bin/bash
#
# Install ArgoCD on production cluster for Challenge 4
#

set -euo pipefail

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-ctf-production-cluster}"
ARGOCD_VERSION="${ARGOCD_VERSION:-5.51.0}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

echo "==> Installing ArgoCD on production cluster..."

# Verify we're on the right cluster
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER_NAME" ]]; then
    echo "Error: Not on production cluster context."
    echo "Current context: $CURRENT_CONTEXT"
    echo "Expected: kind-$CLUSTER_NAME"
    echo ""
    echo "Switch context with: kubectl config use-context kind-$CLUSTER_NAME"
    exit 1
fi

# Check if Helm is installed
if ! command -v helm &> /dev/null; then
    echo "Error: Helm is not installed. Please install Helm first."
    exit 1
fi

# Add ArgoCD Helm repository
echo "Adding ArgoCD Helm repository..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create namespaces
echo "Creating namespaces..."
kubectl apply -f challenges/challenge4/argocd/namespace.yaml

# Install ArgoCD with vulnerable configuration
echo "Installing ArgoCD..."
helm install argocd argo/argo-cd \
  --namespace "$ARGOCD_NAMESPACE" \
  --version "$ARGOCD_VERSION" \
  --values challenges/challenge4/argocd/argocd-values.yaml \
  --wait \
  --timeout 5m

# Apply vulnerable RBAC
echo "Applying vulnerable RBAC configuration..."
kubectl apply -f challenges/challenge4/argocd/vulnerable-rbac.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=300s

# Get admin password
ADMIN_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "admin123")

echo ""
echo "==> ArgoCD installed successfully!"
echo ""
echo "Access ArgoCD:"
echo "  Web UI: https://localhost:30443"
echo "  Username: admin"
echo "  Password: $ADMIN_PASSWORD"
echo ""
echo "Login with CLI:"
echo "  argocd login localhost:30443 --username admin --password $ADMIN_PASSWORD --insecure"
echo ""
echo "Next steps:"
echo "  1. Create production-manifests repository in Gitea"
echo "  2. Apply ArgoCD application: kubectl apply -f challenges/challenge4/argocd/recipe-api-application.yaml"
echo ""
