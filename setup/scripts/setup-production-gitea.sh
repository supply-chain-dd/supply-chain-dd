#!/bin/bash
#
# Install Gitea on production cluster for Challenge 4
# This provides a separate Git service for the production environment
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-production-cluster}"
GITEA_HELM_VERSION="${GITEA_HELM_VERSION:-v12.5.0}"  # Same version as CI cluster
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="sc-admin"
GITEA_ADMIN_PASSWORD="SecurePass123!"
PRODUCTION_GITEA_HTTP_PORT="${PRODUCTION_GITEA_HTTP_PORT:-30004}"  # NodePort for Helm config
PRODUCTION_GITEA_SSH_PORT="${GITEA_PROD_SSH_PORT}"  # From domains.sh

echo "==> Installing Gitea on production cluster..."

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

# Add Gitea Helm repository
echo "Adding Gitea Helm repository..."
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo update

# Create gitea namespace
echo "Creating gitea namespace..."
kubectl create namespace "$GITEA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install Gitea via Helm
echo "Installing Gitea version $GITEA_HELM_VERSION..."
helm upgrade --install gitea gitea-charts/gitea \
  --version "$GITEA_HELM_VERSION" \
  --namespace "$GITEA_NAMESPACE" \
  --set service.http.type=NodePort \
  --set service.http.nodePort="$PRODUCTION_GITEA_HTTP_PORT" \
  --set service.ssh.type=NodePort \
  --set service.ssh.nodePort="$PRODUCTION_GITEA_SSH_PORT" \
  --set gitea.admin.username="$GITEA_ADMIN_USER" \
  --set gitea.admin.password="$GITEA_ADMIN_PASSWORD" \
  --set gitea.admin.email="admin@sc.local" \
  --set redis-cluster.enabled=false \
  --set postgresql-ha.enabled=false \
  --set postgresql.enabled=false \
  --set gitea.config.database.DB_TYPE=sqlite3 \
  --set gitea.config.actions.ENABLED=true \
  --set gitea.config.actions.DEFAULT_ACTIONS_URL=https://github.com \
  --set gitea.config.webhook.ALLOWED_HOST_LIST=*.svc.cluster.local \
  --set gitea.config.server.ROOT_URL=http://gitea-http.gitea.svc.cluster.local:3000 \
  --set gitea.config.server.DOMAIN=gitea-http.gitea.svc.cluster.local \
  --set gitea.config.server.HTTP_PORT=3000 \
  --set persistence.enabled=true \
  --set persistence.size=10Gi \
  --wait \
  --timeout=10m

# Wait for Gitea to be ready
echo "Waiting for Gitea pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n "$GITEA_NAMESPACE" --timeout=300s

echo ""
echo "✓ Gitea $GITEA_HELM_VERSION installed successfully on production cluster!"
echo ""
echo "Access Gitea:"
echo "  Web UI: http://${GITEA_PROD_HOST}"
echo "  SSH: ssh://git@${GITEA_PROD_HOST}:${GITEA_PROD_SSH_PORT}"
echo "  Username: sc-admin"
echo "  Password: SecurePass123!"
echo ""
echo "Internal cluster URL (for ArgoCD):"
echo "  http://gitea-http.gitea.svc.cluster.local:3000"
echo ""
echo "Next steps:"
echo "  1. Seed production-manifests repository: make seed-production-repo"
echo "  2. Configure ArgoCD application: kubectl apply -f challenges/e2e-scenario/argocd/recipe-api-application.yaml"
echo ""
