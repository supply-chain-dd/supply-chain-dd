#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ctf-cluster}"

echo "Cleaning up CTF environment..."

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
