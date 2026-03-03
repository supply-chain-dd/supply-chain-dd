#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ctf-cluster}"
KIND_VERSION="${KIND_VERSION:-v1.27.3}"

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
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    protocol: TCP
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
    endpoint = ["http://kind-registry:5000"]
EOF

echo "✓ KinD cluster '${CLUSTER_NAME}' created successfully"

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "✓ KinD cluster is ready"
