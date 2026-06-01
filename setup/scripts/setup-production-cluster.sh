#!/bin/bash
#
# Setup production KinD cluster for Challenge 4
# This creates a second cluster to simulate the production environment
#

set -euo pipefail

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-production-cluster}"
KIND_VERSION="${KIND_VERSION:-v1.31.4}"
ARGOCD_VERSION="${ARGOCD_VERSION:-5.51.0}"

echo "==> Setting up production KinD cluster for Challenge 4..."

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed. Please install kind first."
    echo "Visit: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

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
      # Gateway API (Envoy Gateway) — access via *.sc.local domains
      - containerPort: ${GATEWAY_PROD_HTTP_PORT}
        hostPort: ${GATEWAY_PROD_HTTP_PORT}
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: ${GATEWAY_PROD_HTTPS_PORT}
        hostPort: ${GATEWAY_PROD_HTTPS_PORT}
        listenAddress: "127.0.0.1"
        protocol: TCP
      # Gitea SSH (TCP — cannot go through HTTP gateway)
      - containerPort: ${GITEA_PROD_SSH_PORT}
        hostPort: ${GITEA_PROD_SSH_PORT}
        protocol: TCP
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    NoNewKeyring = true
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY_PROD_HOST}"]
    endpoint = ["https://${REGISTRY_PROD_HOST}"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."${REGISTRY_PROD_HOST}".tls]
    insecure_skip_verify = true
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
