# Tekton Chains Integration

This document explains how to use Tekton Chains for supply chain security in the CTF environment.

## Overview

Tekton Chains is a Kubernetes CRD controller that enables supply chain security for Tekton Pipelines by:
- Automatically generating cryptographically signed provenance for TaskRuns and PipelineRuns
- Storing attestations in OCI registries
- Supporting in-toto and SLSA provenance formats
- Enabling verification of build artifacts and their origins

## Installation

### Quick Start

```bash
# Install Tekton Chains (requires Tekton Pipelines to be installed first)
make setup-tektonchains

# Verify installation
make verify-tektonchains
```

### What Gets Installed

The setup script:
1. Installs Tekton Chains v0.26.3 (configurable via `TEKTON_CHAINS_VERSION`)
2. Configures Chains with AMPEL/Conforma compatible settings:
   - **Format**: `in-toto` - Standard attestation format compatible with AMPEL and Conforma
   - **Storage**: `oci` - Stores attestations in OCI registries
   - **Deep Inspection**: `true` - Enables deep inspection of pipeline runs

## Configuration

### Default Configuration

The following configuration is automatically applied:

```yaml
# Provenance attestations for PipelineRuns/TaskRuns
artifacts.pipelinerun.format: "in-toto"
artifacts.pipelinerun.storage: "oci"
artifacts.pipelinerun.enable-deep-inspection: "true"
artifacts.taskrun.format: "in-toto"
artifacts.taskrun.storage: "oci"

# Image signing and attestations
artifacts.oci.format: "simplesigning"
artifacts.oci.storage: "oci"
artifacts.oci.signer: "x509"

# Transparency and signing
transparency.enabled: "true"
signers.x509.fulcio.enabled: "false"
```

This configuration enables:
1. **Provenance attestations** - in-toto format (AMPEL/Conforma compatible)
2. **Image signing** - Automatic signing of container images produced by tasks
3. **OCI storage** - Attestations and signatures stored alongside images in OCI registry

### Custom Configuration

To modify the configuration:

```bash
# Edit the chains-config ConfigMap
kubectl edit configmap chains-config -n tekton-chains

# Or patch specific values
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "artifacts.pipelinerun.format": "slsa/v1"
  }
}'

# Restart the controller to apply changes
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
```

### Supported Formats

- **in-toto** (default): Standard attestation format, widely compatible
- **slsa/v1**: SLSA v1.0 provenance format
- **slsa/v2alpha3**: SLSA v2 alpha provenance format

Both in-toto and SLSA formats are compatible with AMPEL and Conforma.

## Image Signing and SBOM Generation

### How It Works

Tekton Chains can automatically sign container images and generate SBOMs when tasks output specific results:

- **`IMAGE_DIGEST`** - The sha256 digest of the built/pushed image
- **`IMAGE_URL`** - The full URL of the image (e.g., `registry.example.com/app:v1.0`)

When Chains detects these results in a TaskRun, it will:
1. Sign the image using the configured signer (x509, KMS, or Fulcio)
2. Generate an SBOM (if configured)
3. Store signatures and attestations in the OCI registry alongside the image

### Enabling Image Signing

**Current Status**: The default setup includes image signing configuration, but tasks need to be updated to output image results.

**Option 1: Use Enhanced Tasks (Recommended)**

Apply the Chains-compatible tasks that include image results:

```bash
# Replace the standard tasks with Chains-compatible versions
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml
```

**Option 2: Update Existing Tasks Manually**

Add `results` to your image build/push tasks:

```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: push-container-image
spec:
  # ... existing params and workspaces ...
  results:
    - name: IMAGE_DIGEST
      description: Digest of the pushed image
    - name: IMAGE_URL
      description: Full URL of the pushed image
  steps:
    - name: push
      image: gcr.io/kaniko-project/executor:latest
      args:
        - --destination=$(params.registry)/$(params.image):$(params.tag)
        - --digest-file=/tekton/results/IMAGE_DIGEST
    - name: write-url
      image: alpine
      script: |
        echo -n "$(params.registry)/$(params.image):$(params.tag)" > /tekton/results/IMAGE_URL
```

### SBOM Generation

To enable SBOM generation, Tekton Chains can integrate with tools like Syft:

```bash
# Configure Chains to generate SBOMs
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "artifacts.oci.format": "simplesigning",
    "artifacts.sbom.format": "cyclonedx",
    "artifacts.sbom.enabled": "true"
  }
}'

# Restart controller
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
```

**Note**: SBOM generation requires the image to be available in the registry when Chains processes the TaskRun.

## Usage with CTF Challenges

### Challenge 1: PR Quality Check Pipeline

The `pr-quality-check-pipeline` automatically generates attestations when run:

```bash
# Run the pipeline
kubectl tkn pipeline start pr-quality-check-pipeline \
  --param pr-repo-url=https://github.com/example/repo.git \
  --param pr-sha=main \
  --param pr-number=1 \
  --workspace name=source,emptyDir="" \
  --showlog

# View the generated attestation
kubectl get pipelineruns -n ctf-challenge -o yaml | grep -A 10 "chains.tekton.dev"
```

### Challenge 2: Push Build Pipeline (Image Signing)

The `push-build-pipeline` generates attestations for container builds and can sign images when using Chains-compatible tasks:

```bash
# Option 1: Use standard tasks (provenance only)
make trigger-challenge2-build

# Option 2: Use Chains-compatible tasks (provenance + image signing)
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml
make trigger-challenge2-build

# Check PipelineRun attestations
kubectl get pipelineruns -n ctf-challenge -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'

# Check TaskRun attestations (image signing)
kubectl get taskruns -n ctf-challenge -l tekton.dev/pipelineTask=push-container-image \
  -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'

# View image signature
cosign verify --insecure-ignore-tlog --key k8s://tekton-chains/signing-secrets \
  registry.registry.svc.cluster.local:5000/recipe-api:latest
```

**With Chains-compatible tasks**, the following artifacts are generated:
- **PipelineRun provenance** - Attestation of the entire pipeline execution
- **TaskRun provenance** - Attestation for the push-container-image task
- **Image signature** - Cryptographic signature of the container image
- **SBOM** (if enabled) - Software Bill of Materials for the image

## Viewing Attestations

### In PipelineRuns

Tekton Chains adds annotations to PipelineRuns:

```bash
# List all pipeline runs with attestations
kubectl get pipelineruns -n ctf-challenge -o custom-columns=\
NAME:.metadata.name,\
SIGNED:.metadata.annotations.chains\.tekton\.dev/signed,\
TRANSPARENCY:.metadata.annotations.chains\.tekton\.dev/transparency

# View full attestation
kubectl get pipelinerun <name> -n ctf-challenge -o jsonpath='{.metadata.annotations}' | jq
```

### In OCI Registry

Attestations are stored alongside container images in the OCI registry:

```bash
# Login to registry
podman login localhost:30000 -u ctf-admin -p CTFRegistryPass123! --tls-verify=false

# Pull attestation (using cosign or oras)
cosign download attestation localhost:30000/recipe-api:latest
```

## Integration with AMPEL

AMPEL can verify Tekton Chains attestations:

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: require-tekton-attestation
spec:
  checks:
    - name: verify-build-attestation
      condition: |
        attestation.predicateType == "https://in-toto.io/Statement/v0.1" &&
        attestation.predicate.builder.id == "https://tekton.dev/chains/v2"
      severity: CRITICAL
      message: "All builds must have valid Tekton Chains attestation"
```

## Integration with Conforma

Conforma can validate compliance using Tekton Chains attestations:

```bash
# Example: Verify pipeline compliance
conforma verify \
  --policy policy.yaml \
  --attestation <(kubectl get pipelinerun <name> -o json)
```

## Verification

### Verify Installation

```bash
make verify-tektonchains
```

Expected output:
```
Verifying Tekton Chains...

Tekton Chains Namespace:
  ✓ Namespace exists

Tekton Chains Controller:
  ✓ Controller deployment exists

Current Configuration Settings:
  Format: in-toto
  Storage: oci
  Deep Inspection: true

✓ Tekton Chains verification complete
```

### Verify Attestation Generation

1. Run a pipeline:
```bash
kubectl tkn pipeline start pr-quality-check-pipeline -n ctf-challenge --showlog
```

2. Check for attestation:
```bash
kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp | tail -1
```

3. Look for `chains.tekton.dev/signed: true` annotation

## Troubleshooting

### Chains Controller Not Starting

```bash
# Check controller logs
kubectl logs -n tekton-chains -l app.kubernetes.io/name=controller

# Check controller status
kubectl get deployment tekton-chains-controller -n tekton-chains
```

### Attestations Not Being Generated

```bash
# Check chains configuration
kubectl get configmap chains-config -n tekton-chains -o yaml

# Verify controller is watching PipelineRuns
kubectl logs -n tekton-chains -l app.kubernetes.io/name=controller | grep "PipelineRun"

# Check for errors
kubectl get events -n tekton-chains --sort-by='.lastTimestamp'
```

### OCI Storage Issues

```bash
# Verify registry is accessible from chains controller
kubectl run test-registry --image=curlimages/curl:latest --rm -i --restart=Never -- \
  curl -k -u ctf-admin:CTFRegistryPass123! https://registry.registry.svc.cluster.local:5000/v2/_catalog

# Check if registry credentials are configured
kubectl get secret -n tekton-chains
```

## Environment Variables

Configure Tekton Chains version:

```bash
# Use specific version
TEKTON_CHAINS_VERSION=v0.25.0 make setup-tektonchains

# Default is v0.26.3
make setup-tektonchains
```

## Security Considerations

### Signing Keys

By default, Tekton Chains generates a signing key automatically. For production:

1. Generate your own signing key:
```bash
cosign generate-key-pair k8s://tekton-chains/signing-secrets
```

2. Configure Chains to use it:
```bash
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "signers.x509.fulcio.enabled": "true"
  }
}'
```

### Transparency Log

Enable Rekor transparency log for public auditability:

```bash
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "transparency.enabled": "true",
    "transparency.url": "https://rekor.sigstore.dev"
  }
}'
```

## References

- [Tekton Chains Documentation](https://tekton.dev/docs/chains/)
- [Tekton Chains GitHub](https://github.com/tektoncd/chains)
- [in-toto Specification](https://in-toto.io/)
- [SLSA Framework](https://slsa.dev/)
- [AMPEL Documentation](https://ampel.dev/)
- [Conforma](https://www.conforma.dev/)

## Next Steps

1. Install Tekton Chains: `make setup-tektonchains`
2. Run pipelines to generate attestations
3. Configure AMPEL policies to enforce attestation requirements
4. Integrate with Conforma for compliance validation
5. Set up Sigstore for production signing and transparency
