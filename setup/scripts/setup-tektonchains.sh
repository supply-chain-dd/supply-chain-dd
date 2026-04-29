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

# Generate signing keys if they don't exist
echo ""
echo "Setting up signing keys..."

# Check if cosign is installed
if ! command -v cosign &>/dev/null; then
    echo "  ❌ cosign not found. Please install cosign first:"
    echo "     https://docs.sigstore.dev/cosign/installation/"
    echo ""
    echo "  Quick install (Linux/macOS):"
    echo "    curl -L https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 -o cosign"
    echo "    chmod +x cosign"
    echo "    sudo mv cosign /usr/local/bin/"
    exit 1
fi

if kubectl get secret signing-secrets -n tekton-chains &>/dev/null; then
    # Check if secret has actual keys
    KEY_COUNT=$(kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data}' | jq 'length' 2>/dev/null || echo "0")
    if [ -z "$KEY_COUNT" ] || [ "$KEY_COUNT" -eq 0 ]; then
        echo "  ⚠️  signing-secrets exists but is empty. Regenerating..."
        kubectl delete secret signing-secrets -n tekton-chains
    else
        echo "  ✓ Signing keys already exist"

        # Get the repository root and save public key if not already saved
        REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
        PUBKEY_FILE="${REPO_ROOT}/cosign.pub"

        if [ ! -f "${PUBKEY_FILE}" ]; then
            echo "  Extracting public key to repository root..."
            kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data.cosign\.pub}' | base64 -d > "${PUBKEY_FILE}"
            echo "  ✓ Public key saved to: ${PUBKEY_FILE}"
        fi
    fi
fi

if ! kubectl get secret signing-secrets -n tekton-chains &>/dev/null; then
    echo "  Generating cosign keypair..."
    echo ""
    echo "  ⚠️  You will be prompted for a password to encrypt the private key."
    echo "  Choose a strong password and remember it (you won't need it for verification)."
    echo ""

    # Generate keypair using cosign (creates Kubernetes secret automatically)
    # User will be prompted for password interactively
    cosign generate-key-pair k8s://tekton-chains/signing-secrets

    # Get the repository root (script is in setup/scripts/)
    REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    PUBKEY_FILE="${REPO_ROOT}/cosign.pub"

    # Save public key to repository root for verification
    # The public key should be in current directory after generation
    if [ -f "cosign.pub" ]; then
        cp cosign.pub "${PUBKEY_FILE}"
        echo "  ✓ Public key saved to: ${PUBKEY_FILE}"
        # Clean up local copy
        rm -f cosign.pub
    else
        # Extract from secret if file doesn't exist
        kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data.cosign\.pub}' | base64 -d > "${PUBKEY_FILE}"
        echo "  ✓ Public key extracted and saved to: ${PUBKEY_FILE}"
    fi

    echo "  ✓ Signing keys generated and stored in signing-secrets"
    echo "  ✓ Private key is encrypted and stored ONLY in Kubernetes secret"
fi

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
echo "Public key for signature verification:"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "${REPO_ROOT}/cosign.pub" ]; then
    echo "  📜 ${REPO_ROOT}/cosign.pub"
    echo ""
    echo "  Verify signatures with:"
    echo "    cosign verify --key ${REPO_ROOT}/cosign.pub <image>"
fi
echo ""
echo "Next steps:"
echo "  1. Update tasks to output IMAGE_DIGEST and IMAGE_URL results"
echo "  2. Configure OCI registry credentials for attestation storage"
echo "  3. Run pipelines to generate attestations, signatures, and SBOMs"
echo "  4. View attestations: kubectl get pipelineruns -n <namespace>"
echo "  5. Verify signatures: cosign verify --key cosign.pub <image>"
echo ""
echo "Documentation:"
echo "  - Tekton Chains: https://tekton.dev/docs/chains/"
echo "  - Image Signing: https://tekton.dev/docs/chains/signing/"
echo "  - Cosign: https://docs.sigstore.dev/cosign/overview/"
echo "  - AMPEL: https://ampel.dev/"
echo "  - Conforma: https://www.conforma.dev/"
echo ""
