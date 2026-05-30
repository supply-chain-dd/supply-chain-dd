#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-registry}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-ci}"

echo "Setting up registry certificate for Tekton pipelines..."

# Check if kubectl is working
if ! kubectl cluster-info &> /dev/null; then
    echo "Error: kubectl is not configured or cluster is not running."
    exit 1
fi

# Check if registry-tls secret exists
if ! kubectl get secret registry-tls -n "${REGISTRY_NAMESPACE}" &> /dev/null; then
    echo "Error: registry-tls secret not found in ${REGISTRY_NAMESPACE} namespace."
    echo "Run 'make setup-registry' first."
    exit 1
fi

# Create target namespace if it doesn't exist
kubectl create namespace "${TARGET_NAMESPACE}" 2>/dev/null || echo "  Namespace '${TARGET_NAMESPACE}' already exists"

# Extract the registry CA certificate from the secret
echo "Extracting registry CA certificate..."
CERT_DATA=$(kubectl get secret registry-tls -n "${REGISTRY_NAMESPACE}" -o jsonpath='{.data.tls\.crt}')

# Create a ConfigMap with the CA certificate in the target namespace
echo "Creating registry-ca-cert ConfigMap in ${TARGET_NAMESPACE} namespace..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-ca-cert
  namespace: ${TARGET_NAMESPACE}
  labels:
    app: registry
    component: ca-cert
data:
  ca.crt: |
$(kubectl get secret registry-tls -n "${REGISTRY_NAMESPACE}" -o jsonpath='{.data.tls\.crt}' | base64 -d | sed 's/^/    /')
EOF

# Verify the ConfigMap was created
if kubectl get configmap registry-ca-cert -n "${TARGET_NAMESPACE}" &> /dev/null; then
    echo "✓ Registry CA certificate ConfigMap created successfully"
    echo ""
    echo "Certificate available at:"
    echo "  ConfigMap: registry-ca-cert"
    echo "  Namespace: ${TARGET_NAMESPACE}"
    echo "  Key: ca.crt"
    echo ""
    echo "To use in Tekton tasks, mount this ConfigMap at /kaniko/ssl/certs/ca-certificates.crt"
else
    echo "✗ Failed to create ConfigMap"
    exit 1
fi
