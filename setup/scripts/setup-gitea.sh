#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

GITEA_HELM_VERSION="${GITEA_HELM_VERSION:-v12.5.0}"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="sc-admin"
GITEA_ADMIN_PASSWORD="SecurePass123!"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-30002}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-30003}"

echo "Installing Gitea Helm chart ${GITEA_HELM_VERSION}..."

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo "Error: helm is not installed. Please install helm first."
    echo "Visit: https://helm.sh/docs/intro/install/"
    exit 1
fi

# Add Gitea Helm repository
echo "Adding Gitea Helm repository..."
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo update

# Create gitea namespace
echo "Creating Gitea namespace..."
kubectl create namespace "${GITEA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Install Gitea with custom values
echo "Installing Gitea via Helm..."
helm upgrade --install gitea gitea-charts/gitea \
  --version "${GITEA_HELM_VERSION}" \
  --namespace "${GITEA_NAMESPACE}" \
  --set service.http.type=ClusterIP \
  --set service.ssh.type=NodePort \
  --set service.ssh.nodePort="${GITEA_SSH_PORT}" \
  --set gitea.admin.username="${GITEA_ADMIN_USER}" \
  --set gitea.admin.password="${GITEA_ADMIN_PASSWORD}" \
  --set gitea.admin.email="admin@sc.local" \
  --set redis-cluster.enabled=false \
  --set postgresql-ha.enabled=false \
  --set postgresql.enabled=false \
  --set gitea.config.database.DB_TYPE=sqlite3 \
  --set gitea.config.actions.ENABLED=true \
  --set gitea.config.actions.DEFAULT_ACTIONS_URL=https://github.com \
  --set gitea.config.webhook.ALLOWED_HOST_LIST=*.svc.cluster.local \
  --set gitea.config.server.ROOT_URL=http://${GITEA_HOST} \
  --set gitea.config.server.DOMAIN=${GITEA_HOST} \
  --set gitea.config.server.HTTP_PORT=3000 \
  --set persistence.enabled=true \
  --set persistence.size=10Gi \
  --wait \
  --timeout=5m

echo "Waiting for Gitea pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n "${GITEA_NAMESPACE}" --timeout=300s

echo "✓ Gitea ${GITEA_HELM_VERSION} installed successfully"
echo ""
echo "Gitea Access Information:"
echo "  Web UI:   http://${GITEA_HOST}"
echo "  SSH:      ssh://git@${GITEA_HOST}:${GITEA_SSH_PORT}"
echo "  Username: ${GITEA_ADMIN_USER}"
echo "  Password: ${GITEA_ADMIN_PASSWORD}"
echo ""
echo "✓ Gitea installation complete"
