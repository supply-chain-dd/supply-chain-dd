#!/bin/bash
#
# Seed victim-repo repository to CTF cluster Gitea
# This creates and populates the repository used for CTF challenges
#

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ctf-cluster}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-30002}"
GITEA_URL="http://localhost:$GITEA_HTTP_PORT"
GITEA_USER="ctf-admin"
GITEA_PASS="CTFSecurePass123!"
REPO_NAME="victim-repo"

echo "==> Seeding victim-repo repository to CTF cluster Gitea..."

# Verify we're on the right cluster
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER_NAME" ]]; then
    echo "Error: Not on CTF cluster context."
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
    echo "Please ensure Gitea is installed: make setup-gitea"
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

# Copy victim repo sample
echo "Copying victim-repo files..."
cp -r challenges/victim-repo-sample/* "$TEMP_DIR/"
cp -r challenges/victim-repo-sample/.gitignore "$TEMP_DIR/" 2>/dev/null || true
cp -r challenges/victim-repo-sample/.tekton "$TEMP_DIR/" 2>/dev/null || true

# Move _git to .git if it exists (restore git history)
if [ -d "$TEMP_DIR/_git" ]; then
    echo "Restoring git history from _git folder..."
    mv "$TEMP_DIR/_git" "$TEMP_DIR/.git"
fi

# Initialize git repository if .git doesn't exist
cd "$TEMP_DIR"
if [ ! -d ".git" ]; then
    echo "Initializing new git repository..."
    git init
    git config user.name "CTF Admin"
    git config user.email "ctf-admin@ctf.local"
    git add .
    git commit -m "Initial commit: Recipe API application"
else
    echo "Using existing git history..."
    git config user.name "CTF Admin"
    git config user.email "ctf-admin@ctf.local"
fi

# Push to Gitea
echo "Pushing to CTF cluster Gitea..."
git remote add origin "$GITEA_URL/$GITEA_USER/$REPO_NAME.git" 2>/dev/null || \
    git remote set-url origin "$GITEA_URL/$GITEA_USER/$REPO_NAME.git"
git push -u origin main --force

echo ""
echo "==> Victim-repo repository seeded successfully!"
echo ""
echo "Repository details:"
echo "  URL: $GITEA_URL/$GITEA_USER/$REPO_NAME"
echo "  Clone URL (external): $GITEA_URL/$GITEA_USER/$REPO_NAME.git"
echo "  Clone URL (internal): http://gitea-http.gitea.svc.cluster.local:3000/$GITEA_USER/$REPO_NAME.git"
echo ""
echo "Next steps:"
echo "  1. Setup CTF challenge: make setup-ctf-challenge"
echo "  2. Test pull request trigger"
echo "  3. Start attack: challenges/challenge1/CTF-CHALLENGE-GUIDE.md"
echo ""
