#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
GITEA_NAMESPACE="gitea"
REGISTRY_NAMESPACE="registry"

echo "Cleaning up deep dive environment..."

# Cleanup Registry if it exists (optional - will be deleted with cluster anyway)
if kubectl get namespace "${REGISTRY_NAMESPACE}" &> /dev/null; then
    echo "Cleaning up Registry..."
    kubectl delete namespace "${REGISTRY_NAMESPACE}" --ignore-not-found || true
    echo "✓ Registry cleaned up"
fi

# Cleanup Gitea if it exists
if command -v helm &> /dev/null && kubectl get namespace "${GITEA_NAMESPACE}" &> /dev/null; then
    echo "Uninstalling Gitea..."
    helm uninstall gitea -n "${GITEA_NAMESPACE}" --ignore-not-found || true
    kubectl delete namespace "${GITEA_NAMESPACE}" --ignore-not-found || true
    echo "✓ Gitea uninstalled"
fi

# Delete kind cluster
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "Deleting KinD cluster: ${CLUSTER_NAME}"
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "✓ Cluster deleted"
else
    echo "Cluster '${CLUSTER_NAME}' not found, skipping..."
fi

echo ""
echo "✓ Cleanup complete"
