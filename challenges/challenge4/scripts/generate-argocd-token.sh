#!/bin/bash
#
# Generate ArgoCD authentication token for .env.production
# This token will be "leaked" in the container image layers (Challenge 2)
#

set -euo pipefail

CLUSTER_NAME="${1:-ctf-production-cluster}"
ARGOCD_NAMESPACE="${2:-argocd}"

echo "==> Generating ArgoCD token for challenge4..."

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=300s

# Get the initial admin password
ADMIN_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "admin123")

echo "ArgoCD admin password: $ADMIN_PASSWORD"

# Port-forward to ArgoCD server (in background)
kubectl port-forward -n "$ARGOCD_NAMESPACE" svc/argocd-server 8080:443 > /dev/null 2>&1 &
PF_PID=$!
sleep 5

# Login and get token
echo "Logging in to ArgoCD..."
ARGOCD_TOKEN=$(argocd login localhost:8080 \
  --username admin \
  --password "$ADMIN_PASSWORD" \
  --insecure \
  --grpc-web 2>&1 | grep -oP 'token: \K.*' || echo "")

# If direct login doesn't return token, create one
if [ -z "$ARGOCD_TOKEN" ]; then
  echo "Creating account token..."
  argocd account generate-token \
    --account admin \
    --server localhost:8080 \
    --insecure \
    --grpc-web > /tmp/argocd-token.txt

  ARGOCD_TOKEN=$(cat /tmp/argocd-token.txt)
fi

# Kill port-forward
kill $PF_PID 2>/dev/null || true

# Output token
echo ""
echo "==> ArgoCD Token Generated:"
echo "$ARGOCD_TOKEN"
echo ""
echo "This token should be added to .env.production as:"
echo "ARGOCD_AUTH_TOKEN=$ARGOCD_TOKEN"
echo ""
echo "ArgoCD Server: argocd-server.argocd.svc.cluster.local"
echo "External Access: https://localhost:30443 (NodePort)"
