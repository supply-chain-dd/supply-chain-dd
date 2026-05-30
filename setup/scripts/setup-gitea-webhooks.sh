#!/bin/bash
#
# Setup Gitea Webhooks for Tekton EventListeners
# Creates webhooks via Gitea API for PR and Push events
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
GITEA_URL="http://${GITEA_HOST}"
GITEA_USER="${GITEA_USER:-sc-admin}"
GITEA_PASS="${GITEA_PASS:-SecurePass123!}"
REPO_NAME="${REPO_NAME:-recipe-api}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-change-me-in-production}"

echo "=========================================="
echo "Setting Up Gitea Webhooks for Tekton"
echo "=========================================="
echo ""

# Verify we're on the right cluster
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER_NAME" ]]; then
    echo "❌ Error: Not on CI cluster context."
    echo "Current context: $CURRENT_CONTEXT"
    echo "Expected: kind-$CLUSTER_NAME"
    echo ""
    echo "Switch context with: kubectl config use-context kind-$CLUSTER_NAME"
    exit 1
fi

# Check if Gitea is accessible
echo "Checking Gitea availability..."
if ! curl -f -s -o /dev/null "$GITEA_URL"; then
    echo "❌ Error: Gitea is not accessible at $GITEA_URL"
    echo "Please ensure Gitea is installed: make setup-gitea"
    exit 1
fi

# Check if repository exists
echo "Checking if repository exists..."
REPO_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GITEA_USER:$GITEA_PASS" \
  "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME")

if [ "$REPO_EXISTS" != "200" ]; then
    echo "❌ Error: Repository '$REPO_NAME' not found"
    echo "Please seed the repository first: make seed-victim-repo"
    exit 1
fi

# Get EventListener service endpoints (cluster-internal URLs)
echo ""
echo "Getting Tekton EventListener endpoints..."

# Get PR EventListener endpoint (Challenge 1)
# EventListeners use ClusterIP services, so we use cluster-internal DNS
if kubectl get svc el-pr-quality-check-listener -n ci >/dev/null 2>&1; then
    PR_LISTENER_URL="http://el-pr-quality-check-listener.ci.svc.cluster.local:8080"
    echo "  ✓ PR Listener: $PR_LISTENER_URL"
else
    echo "⚠  Warning: PR EventListener not found (Challenge 1)"
    echo "   Run: make setup-ci-pr-pipeline"
    PR_LISTENER_URL=""
fi

# Get Push EventListener endpoint (Challenge 2)
if kubectl get svc el-push-build-listener -n ci >/dev/null 2>&1; then
    PUSH_LISTENER_URL="http://el-push-build-listener.ci.svc.cluster.local:8080"
    echo "  ✓ Push Listener: $PUSH_LISTENER_URL"
else
    echo "⚠  Warning: Push EventListener not found (Challenge 2)"
    echo "   Run: make setup-challenge2-tekton"
    PUSH_LISTENER_URL=""
fi

# Function to create or update webhook
create_webhook() {
    local webhook_url=$1
    local webhook_type=$2
    local events=$3
    local description=$4

    if [ -z "$webhook_url" ]; then
        echo "  ⊘ Skipping $description (EventListener not deployed)"
        return
    fi

    echo ""
    echo "Setting up webhook: $description"
    echo "  Target: $webhook_url"
    echo "  Events: $events"

    # Check if webhook already exists
    EXISTING_WEBHOOKS=$(curl -s -u "$GITEA_USER:$GITEA_PASS" \
        "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks")

    # Delete existing webhooks with same URL
    WEBHOOK_IDS=$(echo "$EXISTING_WEBHOOKS" | jq -r ".[] | select(.config.url == \"$webhook_url\") | .id" 2>/dev/null || echo "")
    if [ -n "$WEBHOOK_IDS" ]; then
        echo "  Found existing webhook(s), deleting..."
        for id in $WEBHOOK_IDS; do
            curl -s -X DELETE \
                -u "$GITEA_USER:$GITEA_PASS" \
                "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks/$id"
        done
    fi

    # Create new webhook
    WEBHOOK_PAYLOAD=$(cat <<EOF
{
  "type": "$webhook_type",
  "config": {
    "url": "$webhook_url",
    "content_type": "json",
    "secret": "$WEBHOOK_SECRET"
  },
  "events": $events,
  "active": true
}
EOF
)

    RESULT=$(curl -s -X POST \
        -u "$GITEA_USER:$GITEA_PASS" \
        -H "Content-Type: application/json" \
        -d "$WEBHOOK_PAYLOAD" \
        "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/hooks")

    if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
        WEBHOOK_ID=$(echo "$RESULT" | jq -r '.id')
        echo "  ✓ Webhook created successfully (ID: $WEBHOOK_ID)"
    else
        echo "  ❌ Failed to create webhook"
        echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"
    fi
}

# Create webhooks
echo ""
echo "Creating webhooks..."

# Challenge 1: Pull Request webhook
if [ -n "$PR_LISTENER_URL" ]; then
    create_webhook \
        "$PR_LISTENER_URL" \
        "gitea" \
        '["pull_request"]' \
        "Challenge 1: PR Quality Check"
fi

# Challenge 2: Push webhook
if [ -n "$PUSH_LISTENER_URL" ]; then
    create_webhook \
        "$PUSH_LISTENER_URL" \
        "gitea" \
        '["push"]' \
        "Challenge 2: Push Build Pipeline"
fi

echo ""
echo "=========================================="
echo "✓ Webhook Setup Complete"
echo "=========================================="
echo ""
echo "Configured webhooks for repository: $GITEA_USER/$REPO_NAME"
echo ""
echo "Verify webhooks in Gitea:"
echo "  $GITEA_URL/$GITEA_USER/$REPO_NAME/settings/hooks"
echo ""
echo "Test webhooks:"
echo "  • Challenge 1: Create a pull request in Gitea"
echo "  • Challenge 2: Push a commit to main branch"
echo ""
echo "Monitor pipeline runs:"
echo "  kubectl get pipelineruns -n ci -w"
echo ""
