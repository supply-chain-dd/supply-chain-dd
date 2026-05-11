#!/usr/bin/env bash
set -euo pipefail

TEKTON_DASHBOARD_VERSION="${TEKTON_DASHBOARD_VERSION:-v0.67.0}"
TEKTON_DASHBOARD_NODE_PORT="${TEKTON_DASHBOARD_NODE_PORT:-30001}"

echo "Installing Tekton Dashboard ${TEKTON_DASHBOARD_VERSION}..."

kubectl apply -f "https://infra.tekton.dev/tekton-releases/dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release.yaml"

echo "Waiting for Tekton Dashboard to be ready..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/part-of=tekton-dashboard -n tekton-pipelines --timeout=300s

echo "✓ Tekton Dashboard ${TEKTON_DASHBOARD_VERSION} installed successfully"

echo "Exposing dashboard via NodePort on port ${TEKTON_DASHBOARD_NODE_PORT}..."
kubectl patch svc tekton-dashboard -n tekton-pipelines \
  --type merge \
  -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":9097,\"targetPort\":9097,\"nodePort\":${TEKTON_DASHBOARD_NODE_PORT}}]}}"

echo ""
echo "✓ Tekton Dashboard accessible at http://localhost:${TEKTON_DASHBOARD_NODE_PORT}"
