#!/bin/bash
#
# Setup production KinD cluster for Challenge 4
# This creates a second cluster to simulate the production environment
#

set -euo pipefail

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-ctf-production-cluster}"
KIND_VERSION="${KIND_VERSION:-v1.27.3}"
ARGOCD_VERSION="${ARGOCD_VERSION:-5.51.0}"

echo "==> Setting up production KinD cluster for Challenge 4..."

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed. Please install kind first."
    echo "Visit: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

# Check if cluster already exists
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "Production cluster '${CLUSTER_NAME}' already exists."
    echo "Use 'kind delete cluster --name ${CLUSTER_NAME}' to remove it first."
    exit 1
fi

# Create cluster configuration
echo "Creating production cluster configuration..."
cat > /tmp/production-kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    image: kindest/node:${KIND_VERSION}
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP
EOF

# Create the cluster
echo "Creating production KinD cluster..."
kind create cluster --config /tmp/production-kind-config.yaml

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=ready node --all --timeout=180s --context "kind-${CLUSTER_NAME}"

echo ""
echo "==> Production cluster created successfully!"
echo ""
echo "Cluster name: ${CLUSTER_NAME}"
echo "Context: kind-${CLUSTER_NAME}"
echo ""
echo "Next steps:"
echo "  1. Switch to production cluster: kubectl config use-context kind-${CLUSTER_NAME}"
echo "  2. Install ArgoCD: make setup-argocd"
echo "  3. Create production-manifests repository in Gitea"
echo "  4. Configure ArgoCD application"
echo ""
