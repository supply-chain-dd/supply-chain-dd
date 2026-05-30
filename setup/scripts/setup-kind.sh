#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
KIND_VERSION="${KIND_VERSION:-v1.31.4}"

echo "Setting up KinD cluster: ${CLUSTER_NAME}"

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed. Please install kind first."
    echo "Visit: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

# Check if cluster already exists
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster '${CLUSTER_NAME}' already exists. Use 'make clean' to remove it first."
    exit 1
fi

# Create kind cluster with custom configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  # Gateway API (Envoy Gateway) — access via *.sc.local domains
  - containerPort: ${GATEWAY_HTTP_PORT}
    hostPort: ${GATEWAY_HTTP_PORT}
    listenAddress: "127.0.0.1"
    protocol: TCP
  - containerPort: ${GATEWAY_HTTPS_PORT}
    hostPort: ${GATEWAY_HTTPS_PORT}
    listenAddress: "127.0.0.1"
    protocol: TCP
  # Gitea SSH (TCP — cannot go through HTTP gateway)
  - containerPort: ${GITEA_SSH_PORT}
    hostPort: ${GITEA_SSH_PORT}
    protocol: TCP
EOF

echo "✓ KinD cluster '${CLUSTER_NAME}' created successfully"

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "✓ KinD cluster is ready"
