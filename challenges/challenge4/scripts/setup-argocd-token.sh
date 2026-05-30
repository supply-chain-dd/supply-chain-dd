#!/bin/bash
#
# Configure ArgoCD to accept the token from .env.production
# This makes the leaked token from Challenge 2 work with ArgoCD
#

set -euo pipefail

ARGOCD_NAMESPACE="${1:-argocd}"

# The token that was leaked in .env.production
LEAKED_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE"

echo "==> Configuring ArgoCD to accept the leaked token from Challenge 2..."

# The JWT signature secret that produces the correct token signature
# This is intentionally weak for the deep dive challenge
JWT_SECRET="Deploy_Token_SuperSecret!"

# Encode the secret in base64 for Kubernetes secret
JWT_SECRET_B64=$(echo -n "$JWT_SECRET" | base64 -w 0)

# Update the ArgoCD secret with the known JWT signing key
echo "Setting JWT signing secret..."
kubectl patch secret argocd-secret -n "$ARGOCD_NAMESPACE" \
  -p "{\"data\":{\"server.secretkey\":\"$JWT_SECRET_B64\"}}"

# Add the token ID to the admin account tokens list
echo "Registering token ID in admin account..."
kubectl patch configmap argocd-cm -n "$ARGOCD_NAMESPACE" --type merge \
  -p '{"data":{"accounts.admin.tokens":"sc-deployer"}}'

# Restart ArgoCD server to pick up changes
echo "Restarting ArgoCD server..."
kubectl rollout restart deployment/argocd-server -n "$ARGOCD_NAMESPACE"
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=120s

echo ""
echo "✓ ArgoCD configured to accept the leaked token!"
echo ""
echo "Test with:"
echo "  export ARGOCD_AUTH_TOKEN='$LEAKED_TOKEN'"
echo "  argocd app list --auth-token=\"\$ARGOCD_AUTH_TOKEN\" --server argocd.sc.local:31443 --insecure --grpc-web"
echo ""
