#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

TEKTON_DASHBOARD_VERSION="${TEKTON_DASHBOARD_VERSION:-v0.67.0}"

echo "Installing Tekton Dashboard ${TEKTON_DASHBOARD_VERSION}..."

kubectl apply -f "https://infra.tekton.dev/tekton-releases/dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release.yaml"

echo "Waiting for Tekton Dashboard to be ready..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/part-of=tekton-dashboard -n tekton-pipelines --timeout=300s

echo "✓ Tekton Dashboard ${TEKTON_DASHBOARD_VERSION} installed successfully"
echo ""
echo "✓ Tekton Dashboard accessible at http://${DASHBOARD_HOST}"
