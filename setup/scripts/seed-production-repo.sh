#!/bin/bash
#
# Seed production-manifests repository to production Gitea
# This creates and populates the repository that ArgoCD will sync from
#

set -euo pipefail

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-ctf-production-cluster}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-30004}"
GITEA_URL="http://localhost:$GITEA_HTTP_PORT"
GITEA_USER="ctf-admin"
GITEA_PASS="CTFSecurePass123!"
REPO_NAME="production-manifests"
PRODUCTION_REGISTRY_NODE_PORT="${PRODUCTION_REGISTRY_NODE_PORT:-30082}"
REGISTRY_USER="${REGISTRY_USER:-ctf-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-CTFRegistryPass123!}"

echo "==> Seeding production-manifests repository to production Gitea..."

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

# Check if Gitea is accessible
echo "Checking Gitea availability..."
if ! curl -f -s -o /dev/null "$GITEA_URL"; then
    echo "Error: Gitea is not accessible at $GITEA_URL"
    echo "Please ensure Gitea is installed: make setup-production-gitea"
    exit 1
fi

# Check if repository already exists
echo "Checking if repository already exists..."
REPO_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GITEA_USER:$GITEA_PASS" \
  "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME")

if [ "$REPO_EXISTS" = "200" ]; then
    echo "Repository '$REPO_NAME' already exists. Deleting it first..."
    curl -X DELETE \
      -u "$GITEA_USER:$GITEA_PASS" \
      "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME"
    sleep 2
fi

# Create repository via API
echo "Creating repository '$REPO_NAME' via Gitea API..."
curl -X POST \
  -u "$GITEA_USER:$GITEA_PASS" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":false}" \
  "$GITEA_URL/api/v1/user/repos"

echo ""
echo "Repository created successfully."

# Create temporary directory for repo
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Copy production manifests
echo "Copying production manifests..."
cp -r challenges/challenge4/production-manifests-sample/* "$TEMP_DIR/"

# Query image digest from production registry and substitute placeholder
echo "Querying image digest from production registry..."
IMAGE_DIGEST=$(skopeo inspect --tls-verify=false \
  --creds "${REGISTRY_USER}:${REGISTRY_PASS}" \
  "docker://localhost:${PRODUCTION_REGISTRY_NODE_PORT}/recipe-api:v1.0" 2>/dev/null | jq -r '.Digest') || true

if [ -z "$IMAGE_DIGEST" ] || [ "$IMAGE_DIGEST" = "null" ]; then
    echo "Warning: Could not retrieve image digest from production registry."
    echo "  Using tag-based reference instead of digest pinning."
    sed -i 's|    digest: PLACEHOLDER_DIGEST|    newTag: v1.0|g' "$TEMP_DIR/recipe-api/kustomization.yaml"
else
    echo "  Image digest: $IMAGE_DIGEST"
    sed -i "s|PLACEHOLDER_DIGEST|${IMAGE_DIGEST}|g" "$TEMP_DIR/recipe-api/kustomization.yaml"
fi

# Verify imagePullSecret exists in production namespace
if ! kubectl get secret production-registry-auth -n production &>/dev/null; then
    echo "Creating imagePullSecret in production namespace..."
    kubectl create secret docker-registry production-registry-auth \
      --docker-server="localhost:${PRODUCTION_REGISTRY_NODE_PORT}" \
      --docker-username="${REGISTRY_USER}" \
      --docker-password="${REGISTRY_PASS}" \
      -n production --dry-run=client -o yaml | kubectl apply -f -
fi

# Initialize git repository
cd "$TEMP_DIR"
git init
git config user.name "CTF Admin"
git config user.email "ctf-admin@ctf.local"
git add .
git commit -m "Initial production manifests for recipe-api"

# Push to Gitea
echo "Pushing to production Gitea..."
git remote add origin "$GITEA_URL/$GITEA_USER/$REPO_NAME.git"
git push -u origin main

echo ""
echo "==> Production-manifests repository seeded successfully!"
echo ""
echo "Repository details:"
echo "  URL: $GITEA_URL/$GITEA_USER/$REPO_NAME"
echo "  Clone URL (external): $GITEA_URL/$GITEA_USER/$REPO_NAME.git"
echo "  Clone URL (internal): http://gitea-http.gitea.svc.cluster.local:3000/$GITEA_USER/$REPO_NAME.git"
echo ""
echo "Next steps:"
echo "  1. Apply ArgoCD application: kubectl apply -f challenges/challenge4/argocd/recipe-api-application.yaml"
echo "  2. Verify ArgoCD sync: kubectl get applications -n argocd"
echo ""
