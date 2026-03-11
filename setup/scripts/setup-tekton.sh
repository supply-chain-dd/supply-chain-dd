#!/usr/bin/env bash
set -euo pipefail

TEKTON_PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-v1.9.0}"
TEKTON_TRIGGERS_VERSION="${TEKTON_TRIGGERS_VERSION:-v0.34.0}"

echo "Installing Tekton Pipelines..."

# Install Tekton Pipelines
kubectl apply -f "https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml"

echo "Waiting for Tekton Pipelines to be ready..."
kubectl wait --for=condition=Ready pods --all -n tekton-pipelines --timeout=300s

echo "✓ Tekton Pipelines ${TEKTON_PIPELINE_VERSION} installed successfully"

# Install Tekton Triggers (optional, comment out if not needed)
echo "Installing Tekton Triggers..."
kubectl apply -f "https://infra.tekton.dev/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml"
kubectl apply -f "https://infra.tekton.dev/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/interceptors.yaml"

echo "Waiting for Tekton to be ready..."
kubectl wait --for=condition=Ready pods --all -n tekton-pipelines --timeout=300s

echo "Waiting for Tekton Pipeline Resolvers to be ready..."
kubectl wait --for=condition=Ready pods --all -n tekton-pipelines-resolvers --timeout=300s 2>/dev/null || true

echo "✓ Tekton Triggers ${TEKTON_TRIGGERS_VERSION} installed successfully"


echo "✓ Tekton installation complete"

