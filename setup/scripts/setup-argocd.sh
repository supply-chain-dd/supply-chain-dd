#!/bin/bash
#
# Install ArgoCD on production cluster for Challenge 4
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-production-cluster}"
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
kubectl apply -f challenges/e2e-scenario/argocd/namespace.yaml

# Install ArgoCD with vulnerable configuration
echo "Installing ArgoCD..."
helm install argocd argo/argo-cd \
  --namespace "$ARGOCD_NAMESPACE" \
  --version "$ARGOCD_VERSION" \
  --values challenges/e2e-scenario/argocd/argocd-values.yaml \
  --wait \
  --timeout 5m

# Apply vulnerable RBAC
echo "Applying vulnerable RBAC configuration..."
kubectl apply -f challenges/e2e-scenario/argocd/vulnerable-rbac.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=300s

# Set admin password to "admin123" (weak password for the deep dive)
echo "Configuring admin password..."
ADMIN_PASSWORD="admin123"

# Generate bcrypt hash and update secret
python3 -c "import bcrypt; import base64; print(base64.b64encode(bcrypt.hashpw(b'${ADMIN_PASSWORD}', bcrypt.gensalt(rounds=10))).decode())" > /tmp/admin-password-hash
ADMIN_HASH=$(cat /tmp/admin-password-hash)
kubectl patch secret argocd-secret -n "$ARGOCD_NAMESPACE" -p "{\"data\":{\"admin.password\":\"$ADMIN_HASH\"}}"
rm /tmp/admin-password-hash

# Configure ArgoCD to accept the leaked token from Challenge 2
echo "Configuring leaked ArgoCD token..."
"$SCRIPT_DIR/../../challenges/e2e-scenario/scripts/setup-argocd-token.sh" "$ARGOCD_NAMESPACE"

# Get the leaked token for display
LEAKED_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE"

echo ""
echo "==> ArgoCD installed successfully!"
# Create Gateway TLSRoute for ArgoCD
if kubectl get gateway sc-local -n envoy-gateway-system &>/dev/null; then
    echo "Creating Gateway HTTPRoute for ArgoCD..."
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: ${ARGOCD_NAMESPACE}
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: http
  hostnames:
  - "${ARGOCD_DOMAIN}"
  rules:
  - backendRefs:
    - name: argocd-server
      port: 80
EOF
    echo "  ✓ ArgoCD Gateway route created"
fi

echo ""
echo "Access ArgoCD:"
echo "  Web UI: http://${ARGOCD_HOST}"
echo "  Username: admin"
echo "  Password: $ADMIN_PASSWORD"
echo ""
echo "Leaked ArgoCD Token (from Challenge 2 .env.production):"
echo "  $LEAKED_TOKEN"
echo ""
echo "Login with CLI (password):"
echo "  echo y | argocd login ${ARGOCD_HOST} --username admin --password $ADMIN_PASSWORD --insecure --grpc-web"
echo ""
echo "Login with CLI (token from .env.production):"
echo "  export ARGOCD_AUTH_TOKEN='$LEAKED_TOKEN'"
echo "  argocd app list --auth-token=\"\$ARGOCD_AUTH_TOKEN\" --server ${ARGOCD_HOST} --insecure --grpc-web"
echo ""
echo "Next steps:"
echo "  1. Create production-manifests repository in Gitea"
echo "  2. Apply ArgoCD application: kubectl apply -f challenges/e2e-scenario/argocd/recipe-api-application.yaml"
echo ""
