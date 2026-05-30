#!/bin/bash
#
# Test that the leaked ArgoCD token from .env.production works
#

set -euo pipefail

echo "==> Testing Challenge 4: ArgoCD Token Authentication"
echo ""

# The token from .env.production
LEAKED_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE"

echo "1. Testing ArgoCD token authentication..."
export ARGOCD_AUTH_TOKEN="$LEAKED_TOKEN"

# Test app list
echo "   Running: argocd app list --auth-token=\$ARGOCD_AUTH_TOKEN --server argocd.sc.local:31443 --insecure --grpc-web"
if argocd app list --auth-token="$ARGOCD_AUTH_TOKEN" --server argocd.sc.local:31443 --insecure --grpc-web > /dev/null 2>&1; then
    echo "   ✓ Token authentication successful!"
else
    echo "   ✗ Token authentication failed!"
    exit 1
fi

echo ""
echo "2. Testing application access..."
if argocd app get recipe-api-production --auth-token="$ARGOCD_AUTH_TOKEN" --server argocd.sc.local:31443 --insecure --grpc-web > /dev/null 2>&1; then
    echo "   ✓ Can access recipe-api-production application!"
else
    echo "   ⚠ recipe-api-production application not found (may not be deployed yet)"
fi

echo ""
echo "3. Testing web UI access (password)..."
echo "   URL: https://argocd.sc.local:31443"
echo "   Username: admin"
echo "   Password: admin123"

# Test login with password
if echo y | argocd login argocd.sc.local:31443 --username admin --password admin123 --insecure --grpc-web > /dev/null 2>&1; then
    echo "   ✓ Web UI login credentials work!"
else
    echo "   ✗ Web UI login failed!"
    exit 1
fi

echo ""
echo "==> All tests passed! Challenge 4 is ready."
echo ""
echo "Attackers can use this token (from .env.production) to access ArgoCD:"
echo "  export ARGOCD_AUTH_TOKEN='$LEAKED_TOKEN'"
echo "  argocd app list --auth-token=\"\$ARGOCD_AUTH_TOKEN\" --server argocd.sc.local:31443 --insecure --grpc-web"
echo ""
