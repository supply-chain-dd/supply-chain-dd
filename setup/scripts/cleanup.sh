#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ctf-cluster}"
GITEA_NAMESPACE="gitea"

echo "Cleaning up CTF environment..."

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
