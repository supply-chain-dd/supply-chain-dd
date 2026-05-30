#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "Configuring Tekton Chains Registry Trust"
echo "=========================================="
echo ""

# Check if registry CA cert exists in ci namespace
if ! kubectl get configmap registry-ca-cert -n ci &>/dev/null; then
    echo "❌ registry-ca-cert ConfigMap not found in ci namespace"
    echo "   Please run: make setup-registry"
    exit 1
fi

echo "Step 1: Copying registry CA certificate to tekton-chains namespace..."
kubectl get configmap registry-ca-cert -n ci -o yaml | \
    sed 's/namespace: ci/namespace: tekton-chains/' | \
    kubectl apply -f -
echo "  ✓ ConfigMap copied to tekton-chains namespace"

echo ""
echo "Step 2: Patching Tekton Chains controller to trust registry certificate..."

# Check if patch already applied
if kubectl get deployment tekton-chains-controller -n tekton-chains -o yaml | grep -q "registry-ca-cert"; then
    echo "  ⚠️  Registry CA cert already mounted, skipping patch"
else
    # Create a temporary file with the patch
    cat > /tmp/chains-patch.yaml << 'EOF'
spec:
  template:
    spec:
      volumes:
      - name: registry-ca-cert
        configMap:
          name: registry-ca-cert
      containers:
      - name: tekton-chains-controller
        volumeMounts:
        - name: registry-ca-cert
          mountPath: /etc/registry-certs
          readOnly: true
        env:
        - name: SSL_CERT_DIR
          value: /etc/ssl/certs:/etc/registry-certs
EOF

    # Apply the patch
    kubectl patch deployment tekton-chains-controller -n tekton-chains --patch-file /tmp/chains-patch.yaml

    # Clean up
    rm /tmp/chains-patch.yaml

    echo "  ✓ Deployment patched"
fi

echo ""
echo "Step 3: Waiting for Tekton Chains controller to restart..."
kubectl rollout status deployment tekton-chains-controller -n tekton-chains --timeout=120s

echo ""
echo "=========================================="
echo "✓ Tekton Chains Registry Trust Configured"
echo "=========================================="
echo ""
echo "Changes made:"
echo "  1. ✓ Copied registry-ca-cert ConfigMap to tekton-chains namespace"
echo "  2. ✓ Mounted certificate in Tekton Chains controller"
echo "  3. ✓ Configured SSL_CERT_FILE environment variable"
echo "  4. ✓ Restarted controller"
echo ""
echo "Tekton Chains can now access the local registry at:"
echo "  registry.registry.svc.cluster.local:5000"
echo ""
echo "Next: Trigger a pipeline run to test image signing"
echo "  make trigger-challenge2-build"
echo ""
