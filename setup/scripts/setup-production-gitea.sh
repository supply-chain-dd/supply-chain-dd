#!/bin/bash
#
# Install Gitea on production cluster for Challenge 4
# This provides a separate Git service for the production environment
#

set -euo pipefail

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-ctf-production-cluster}"
GITEA_HELM_VERSION="${GITEA_HELM_VERSION:-v12.5.0}"  # Same version as CTF cluster
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="ctf-admin"
GITEA_ADMIN_PASSWORD="CTFSecurePass123!"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-30004}"  # Different port to avoid conflict with CTF cluster
GITEA_SSH_PORT="${GITEA_SSH_PORT:-30005}"

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
  --set service.http.nodePort="$GITEA_HTTP_PORT" \
  --set service.ssh.type=NodePort \
  --set service.ssh.nodePort="$GITEA_SSH_PORT" \
  --set gitea.admin.username="$GITEA_ADMIN_USER" \
  --set gitea.admin.password="$GITEA_ADMIN_PASSWORD" \
  --set gitea.admin.email="admin@ctf.local" \
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
echo "  Web UI: http://localhost:$GITEA_HTTP_PORT"
echo "  SSH: ssh://git@localhost:$GITEA_SSH_PORT"
echo "  Username: ctf-admin"
echo "  Password: CTFSecurePass123!"
echo ""
echo "Internal cluster URL (for ArgoCD):"
echo "  http://gitea-http.gitea.svc.cluster.local:3000"
echo ""
echo "Next steps:"
echo "  1. Seed production-manifests repository: make seed-production-repo"
echo "  2. Configure ArgoCD application: kubectl apply -f challenges/challenge4/argocd/recipe-api-application.yaml"
echo ""
