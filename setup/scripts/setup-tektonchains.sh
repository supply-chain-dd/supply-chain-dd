#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

TEKTON_CHAINS_VERSION="${TEKTON_CHAINS_VERSION:-v0.26.3}"

echo "Checking prerequisites..."
if ! kubectl get ksvc fulcio -n fulcio-system &>/dev/null; then
    echo "  Fulcio not found. Run 'make setup-sigstore-local' first."
    exit 1
fi
if ! kubectl get ksvc rekor -n rekor-system &>/dev/null; then
    echo "  Rekor not found. Run 'make setup-sigstore-local' first."
    exit 1
fi
echo "  Fulcio and Rekor are running"

echo ""
echo "Installing Tekton Chains ${TEKTON_CHAINS_VERSION}..."

RELEASE_FILE="release.yaml"

if [ ! -f "${RELEASE_FILE}" ]; then
    echo "  Downloading Tekton Chains ${TEKTON_CHAINS_VERSION} release manifest..."
    curl -fsSL -o "${RELEASE_FILE}" "https://infra.tekton.dev/tekton-releases/chains/previous/${TEKTON_CHAINS_VERSION}/release.yaml"
fi
kubectl apply -f "${RELEASE_FILE}"

echo "Waiting for Tekton Chains to be ready..."
kubectl wait --for=condition=Ready pods --all -n tekton-chains --timeout=300s

echo "Tekton Chains ${TEKTON_CHAINS_VERSION} installed successfully"

# The signing-secrets Secret must exist (the controller deployment mounts it
# as a volume). With Fulcio-based signing, no cosign keypair is needed —
# Fulcio provides ephemeral certificates — but the Secret must still be
# present to satisfy the volume mount.
echo ""
echo "Ensuring signing-secrets Secret exists..."
if ! kubectl get secret signing-secrets -n tekton-chains &>/dev/null; then
    kubectl create secret generic signing-secrets -n tekton-chains
    echo "  Created empty signing-secrets (Fulcio provides ephemeral certs)"
else
    echo "  signing-secrets already exists"
fi

# Configure Tekton Chains to use the internal Sigstore stack
echo ""
echo "Configuring Tekton Chains for internal Sigstore (Fulcio + Rekor)..."

kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "artifacts.pipelinerun.format": "in-toto",
    "artifacts.pipelinerun.storage": "oci",
    "artifacts.pipelinerun.signer": "x509",
    "artifacts.pipelinerun.enable-deep-inspection": "true",
    "artifacts.taskrun.format": "in-toto",
    "artifacts.taskrun.storage": "oci",
    "artifacts.oci.signer": "none",
    "signers.x509.fulcio.enabled": "true",
    "signers.x509.fulcio.address": "http://fulcio.fulcio-system.svc",
    "transparency.enabled": "true",
    "transparency.url": "http://rekor.rekor-system.svc"
  }
}'

echo "Tekton Chains configured with:"
echo "  - Provenance format: in-toto (compatible with Conforma)"
echo "  - Provenance storage: OCI registry"
echo "  - Provenance signer: x509 (Fulcio keyless)"
echo "  - Deep inspection: enabled"
echo "  - OCI image signing: DISABLED (handled by in-pipeline sign-image-keyless task)"
echo "  - Fulcio address: http://fulcio.fulcio-system.svc"
echo "  - Transparency log: http://rekor.rekor-system.svc"

# Restart chains controller to apply configuration
echo ""
echo "Restarting Tekton Chains controller to apply configuration..."
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
kubectl rollout status deployment tekton-chains-controller -n tekton-chains --timeout=120s

echo "Tekton Chains configuration applied and controller restarted"

# Display current configuration
echo ""
echo "Current Tekton Chains configuration:"
kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data}' | jq -r 'to_entries[] | "\(.key): \(.value)"'

echo ""
echo "Tekton Chains setup complete"
echo ""
echo "Service discovery:"
echo "  - OIDC token: projected at /var/run/sigstore/cosign/oidc-token (audience: sigstore)"
echo "  - Fulcio:     http://fulcio.fulcio-system.svc"
echo "  - Rekor:      http://rekor.rekor-system.svc"
echo ""
echo "Verification (keyless):"
echo "  ISSUER=\$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')"
echo "  cosign verify \\"
echo "    --certificate-identity=https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller \\"
echo "    --certificate-oidc-issuer=\$ISSUER \\"
echo "    --rekor-url=http://${REKOR_HOST} \\"
echo "    --insecure-ignore-sct \\"
echo "    --registry-cacert=setup/certs/registry.crt \\"
echo "    <image>"
echo ""
