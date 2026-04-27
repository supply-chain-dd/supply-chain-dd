#!/usr/bin/env bash
set -euo pipefail

TEKTON_CHAINS_VERSION="${TEKTON_CHAINS_VERSION:-v0.26.3}"

echo "Installing Tekton Chains ${TEKTON_CHAINS_VERSION}..."

# Install Tekton Chains
wget "https://infra.tekton.dev/tekton-releases/chains/previous/${TEKTON_CHAINS_VERSION}/release.yaml"
kubectl apply -f release.yaml

echo "Waiting for Tekton Chains to be ready..."
kubectl wait --for=condition=Ready pods --all -n tekton-chains --timeout=300s

echo "✓ Tekton Chains ${TEKTON_CHAINS_VERSION} installed successfully"

# Configure Tekton Chains
echo ""
echo "Configuring Tekton Chains..."

# Create ConfigMap with AMPEL/Conforma compatible settings + image signing + SBOM
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "artifacts.pipelinerun.format": "in-toto",
    "artifacts.pipelinerun.storage": "oci",
    "artifacts.pipelinerun.enable-deep-inspection": "true",
    "artifacts.taskrun.format": "in-toto",
    "artifacts.taskrun.storage": "oci",
    "artifacts.oci.format": "simplesigning",
    "artifacts.oci.storage": "oci",
    "artifacts.oci.signer": "x509",
    "transparency.enabled": "true",
    "signers.x509.fulcio.enabled": "false"
  }
}'

echo "✓ Tekton Chains configured with:"
echo "  - Provenance format: in-toto (compatible with AMPEL and Conforma)"
echo "  - Provenance storage: OCI registry"
echo "  - Deep inspection: enabled"
echo "  - Image signing: enabled (simplesigning format)"
echo "  - Image signature storage: OCI registry"
echo "  - Signer: x509 (self-signed keys)"

# Restart chains controller to apply configuration
echo ""
echo "Restarting Tekton Chains controller to apply configuration..."
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
kubectl rollout status deployment tekton-chains-controller -n tekton-chains --timeout=120s

echo "✓ Tekton Chains configuration applied and controller restarted"

# Display current configuration
echo ""
echo "Current Tekton Chains configuration:"
kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data}' | jq -r 'to_entries[] | select(.key | startswith("artifacts.pipelinerun")) | "\(.key): \(.value)"'

echo ""
echo "✓ Tekton Chains setup complete"
echo ""
echo "⚠️  IMPORTANT: For image signing to work, tasks must output IMAGE_DIGEST and IMAGE_URL results."
echo "   See TEKTON-CHAINS.md for task configuration examples."
echo ""
echo "Next steps:"
echo "  1. Update tasks to output IMAGE_DIGEST and IMAGE_URL results"
echo "  2. Configure OCI registry credentials for attestation storage"
echo "  3. Run pipelines to generate attestations, signatures, and SBOMs"
echo "  4. View attestations: kubectl get pipelineruns -n <namespace>"
echo "  5. Verify signatures: cosign verify <image>"
echo ""
echo "Documentation:"
echo "  - Tekton Chains: https://tekton.dev/docs/chains/"
echo "  - Image Signing: https://tekton.dev/docs/chains/signing/"
echo "  - AMPEL: https://ampel.dev/"
echo "  - Conforma: https://www.conforma.dev/"
echo ""
