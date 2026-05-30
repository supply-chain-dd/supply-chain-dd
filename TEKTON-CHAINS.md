# Tekton Chains Integration

This document explains how to use Tekton Chains for supply chain security in the deep dive environment.

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
2. Generates cosign keypair using `cosign generate-key-pair` and saves the public key to `cosign.pub`
3. Configures Chains with AMPEL/Conforma compatible settings:
   - **Format**: `in-toto` - Standard attestation format compatible with AMPEL and Conforma
   - **Storage**: `oci` - Stores attestations in OCI registries
   - **Deep Inspection**: `true` - Enables deep inspection of pipeline runs
   - **Image Signing**: Enabled with cosign signer

**Requirements**: The script requires `cosign` to be installed. See [Cosign installation](https://docs.sigstore.dev/cosign/installation/).

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

## Usage with Deep Dive Challenges

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
kubectl get pipelineruns -n ci -o yaml | grep -A 10 "chains.tekton.dev"
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
kubectl get pipelineruns -n ci -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'

# Check TaskRun attestations (image signing)
kubectl get taskruns -n ci -l tekton.dev/pipelineTask=push-container-image \
  -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'

# Verify image signature (using public key file)
cosign verify --insecure-ignore-tlog --key cosign.pub \
  registry.sc.local:30443/recipe-api:v1.0 --registry-cacert=setup/certs/registry.crt

# Or verify using Kubernetes secret directly
cosign verify --insecure-ignore-tlog --key k8s://tekton-chains/signing-secrets --registry-cacert setup/certs/registry.crt \
  registry.sc.local:30443/recipe-api:latest/recipe-api:v1.0
```

**Note**: The setup script saves the cosign public key to `cosign.pub` at the repository root for convenient signature verification.

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
kubectl get pipelineruns -n ci -o custom-columns=\
NAME:.metadata.name,\
SIGNED:.metadata.annotations.chains\.tekton\.dev/signed,\
TRANSPARENCY:.metadata.annotations.chains\.tekton\.dev/transparency

# View full attestation
kubectl get pipelinerun <name> -n ci -o jsonpath='{.metadata.annotations}' | jq
```

### In OCI Registry

Attestations are stored alongside container images in the OCI registry:

```bash
# Login to registry
podman login registry.sc.local:30443 -u sc-admin -p RegistryPass123! --tls-verify=false

# Pull attestation (using cosign or oras)
cosign download attestation registry.sc.local:30443/recipe-api:latest
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

Conforma (Enterprise Contract) validates that a container image has been properly signed
and attested by Tekton Chains before it can be deployed. It uses the `ec` CLI to evaluate
the image's cosign signature and SLSA Provenance attestation against a Rego-based policy.

### Install the ec CLI

```bash
make install-conforma          # downloads ec binary to ~/.local/bin/ec
make setup-conforma            # also creates an EnterpriseContractPolicy CR on the cluster
make verify-conforma           # check ec is installed and print a sample validate command
```

### Validate an image from the command line

```bash
# After make setup-tektonchains a cosign key pair is in cosign.pub / signing-secrets.
# After make trigger-challenge2-build-with-chains the image is signed by Chains.

# ec is a Go binary — SSL_CERT_FILE tells it to trust the local registry's self-signed CA.
# Use --images (not --image) with an ApplicationSnapshot spec so the source
# git URL and revision are passed to Conforma for slsa_source_correlated checks.
SSL_CERT_FILE=setup/certs/registry.crt \
ec validate image \
  --images '{"components":[{"name":"recipe-api","containerImage":"registry.sc.local:30443/recipe-api:v1.0","source":{"git":{"url":"http://gitea-http.gitea.svc.cluster.local:3000/sc-admin/recipe-api.git","revision":"ed9f32e8da7979f3aa4e3ce8dfedb0a48d5afd9e"}}}]}' \
  --public-key cosign.pub \
  --policy '{"sources":[{"name":"sc-minimal","policy":["github.com/conforma/policy//policy/lib","github.com/conforma/policy//policy/release"],"config":{"include":["@minimal"],"exclude":["base_image_registries.base_image_info_found","cve.cve_results_found"]}}]}' \
  --ignore-rekor \
  --extra-rule-data allowed_registry_prefixes=registry.registry.svc.cluster.local:5000 \
  --extra-rule-data allowed_registry_prefixes=registry.sc.local:30443 \
  --extra-rule-data allowed_registry_prefixes=docker.io \
  --extra-rule-data allowed_registry_prefixes=gcr.io \
  --extra-rule-data allowed_registry_prefixes=golang \
  --output text
```

### Validate AFTER the build pipeline (other pipeline or command line) (Challenge 2 / Challenge 3)

The `push-build-pipeline-with-chains` pipeline builds, pushes, signs and attests the
image but does **not** run Conforma validation inside the pipeline. This is because
Tekton Chains generates PipelineRun attestations only AFTER the pipeline completes —
rules like `attestation_type.pipelinerun_attestation_found` and
`slsa_source_correlated.*` cannot be satisfied from within the pipeline.

```bash
# Trigger the Chains pipeline
make trigger-challenge2-build-with-chains

# The pipeline stages are:
#   verify-source-provenance               (validates repo URL + branch containment, generates Source VSA)
#     → git-clone                          (emits url + commit)
#     → build-go-app → quality-checks
#     → push-container-image-with-chains   (emits IMAGE_URL + IMAGE_DIGEST)
#        [Tekton Chains signs + attests asynchronously]
#        → create-source-vsa              (attaches unsigned Source VSA via OCI referrers)
#        → generate-sbom                  (Trivy SPDX SBOM + oras attach)

# Monitor progress
kubectl get pipelineruns -n ci -w

# After the pipeline finishes, validate from the command line:
SSL_CERT_FILE=setup/certs/registry.crt \
ec validate image \
  --images '{"components":[{"name":"recipe-api","containerImage":"registry.sc.local:30443/recipe-api:v1.0","source":{"git":{"url":"http://gitea-http.gitea.svc.cluster.local:3000/sc-admin/recipe-api.git","revision":"ed9f32e8da7979f3aa4e3ce8dfedb0a48d5afd9e"}}}]}' \
  --public-key cosign.pub \
  --policy '{"sources":[{"name":"sc-minimal","policy":["github.com/conforma/policy//policy/lib","github.com/conforma/policy//policy/release"],"config":{"include":["@minimal"],"exclude":["base_image_registries.base_image_info_found","cve.cve_results_found"]}}]}' \
  --ignore-rekor \
  --extra-rule-data allowed_registry_prefixes=registry.registry.svc.cluster.local:5000 \
  --extra-rule-data allowed_registry_prefixes=registry.sc.local:30443 \
  --extra-rule-data allowed_registry_prefixes=docker.io \
  --extra-rule-data allowed_registry_prefixes=gcr.io \
  --extra-rule-data allowed_registry_prefixes=golang \
  --output text
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
kubectl tkn pipeline start pr-quality-check-pipeline -n ci --showlog
```

2. Check for attestation:
```bash
kubectl get pipelineruns -n ci --sort-by=.metadata.creationTimestamp | tail -1
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

### Missing Signing Keys (Common Issue)

**Symptoms**:
- Chains controller logs show: `error configuring cosign signer: no valid private key found`
- Or: `No signer cosign configured for tekton`
- PipelineRuns marked as `signed: "true"` but no signatures in registry

**Diagnosis**:
```bash
# Check if signing secret exists and has keys
kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data}' | jq 'keys'
# Should show: ["cosign.key", "cosign.password", "cosign.pub"]

# Check controller logs for signing errors
kubectl logs -n tekton-chains -l app.kubernetes.io/name=controller --tail=50 | grep -i "cosign\|signer\|error"
```

**Solution**:
The setup script should create keys automatically, but if they're missing:

```bash
# Ensure cosign is installed
if ! command -v cosign &>/dev/null; then
    echo "Install cosign: https://docs.sigstore.dev/cosign/installation/"
    exit 1
fi

# Delete empty secret if it exists
kubectl delete secret signing-secrets -n tekton-chains 2>/dev/null || true

# Generate cosign keypair (you'll be prompted for a password)
cosign generate-key-pair k8s://tekton-chains/signing-secrets

# Save public key to repository root
kubectl get secret signing-secrets -n tekton-chains \
    -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub

# Restart Chains controller to pick up keys
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
kubectl rollout status deployment tekton-chains-controller -n tekton-chains
```

**Verification**:
```bash
# Check logs for successful signer initialization
kubectl logs -n tekton-chains -l app.kubernetes.io/name=controller --tail=20

# Should see no errors about missing keys
```

### Image Signing Not Working

**Symptoms**:
- PipelineRuns are signed (provenance generated)
- But images in registry have no signatures
- TaskRuns for image push have no IMAGE_DIGEST/IMAGE_URL results

**Diagnosis**:
```bash
# Check if tasks output IMAGE_DIGEST and IMAGE_URL results
kubectl get task push-container-image -n ci -o yaml | grep -A 5 "^  results:"

# Check TaskRun results
TASKRUN=$(kubectl get taskruns -n ci \
  -l tekton.dev/pipelineTask=push-container-image \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)

kubectl get $TASKRUN -n ci -o jsonpath='{.status.taskResults}'
# Should show IMAGE_DIGEST and IMAGE_URL
```

**Solution**:
Standard tasks don't include image results. Use Chains-compatible tasks:

```bash
# Apply tasks with IMAGE_DIGEST and IMAGE_URL results
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml

# Trigger a new build
make trigger-challenge2-build

# Verify TaskRun has results
kubectl get taskruns -n ci \
  -l tekton.dev/pipelineTask=push-container-image \
  --sort-by=.metadata.creationTimestamp -o name | tail -1 | \
  xargs -I {} kubectl get {} -n ci -o jsonpath='{.status.taskResults[*].name}'
# Should output: IMAGE_DIGEST IMAGE_URL
```

**What's Different**:
The Chains-compatible tasks include:
- `results` section declaring IMAGE_DIGEST and IMAGE_URL
- Kaniko's `--digest-file` flag to capture image digest
- Additional step to write IMAGE_URL to results

See [IMAGE-SIGNING-SBOM.md](IMAGE-SIGNING-SBOM.md) for detailed comparison.

### Registry TLS Certificate Errors

**Symptoms**:
- Chains controller logs show: `tls: failed to verify certificate: x509: certificate signed by unknown authority`
- Or: `GET https://registry.registry.svc.cluster.local:5000/v2/: tls: failed to verify certificate`
- Images aren't being signed even though TaskRuns output IMAGE_DIGEST and IMAGE_URL

**Diagnosis**:
```bash
# Check Chains controller logs
kubectl logs -n tekton-chains -l app.kubernetes.io/name=controller --tail=50 | grep -i "tls\|x509\|certificate"

# Check if registry CA cert is mounted
kubectl get deployment tekton-chains-controller -n tekton-chains \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="registry-ca-cert")].name}'
# Should output: registry-ca-cert
```

**Root Cause**:
The local registry uses a self-signed certificate. Tekton Chains controller doesn't trust it by default.

**Solution**:
```bash
# Run the registry trust setup script
cd setup && ./scripts/setup-tektonchains-registry-trust.sh

# Or manually:
# 1. Copy registry CA cert to tekton-chains namespace
kubectl get configmap registry-ca-cert -n ci -o yaml | \
    sed 's/namespace: ci/namespace: tekton-chains/' | \
    kubectl apply -f -

# 2. Patch Tekton Chains deployment
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

kubectl patch deployment tekton-chains-controller -n tekton-chains --patch-file /tmp/chains-patch.yaml
rm /tmp/chains-patch.yaml

# 3. Wait for restart
kubectl rollout status deployment tekton-chains-controller -n tekton-chains
```

**Verification**:
```bash
# Check SSL_CERT_DIR is set
kubectl get deployment tekton-chains-controller -n tekton-chains \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SSL_CERT_DIR")].value}'
# Should output: /etc/ssl/certs:/etc/registry-certs

# Trigger a pipeline and check logs
kubectl logs -n tekton-chains -l app.kubernetes.io/name=controller --tail=20
# Should see no TLS errors
```

### OCI Storage Issues

```bash
# Verify registry is accessible from chains controller
kubectl run test-registry --image=curlimages/curl:latest --rm -i --restart=Never -- \
  curl -k -u sc-admin:RegistryPass123! https://registry.registry.svc.cluster.local:5000/v2/_catalog

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

**Important**: Tekton Chains does NOT automatically generate signing keys. You must create them manually.

The setup script (`make setup-tektonchains`) creates a cosign keypair using the recommended method from Tekton Chains documentation.

**For Development/Testing** (cosign keys):
```bash
# Ensure cosign is installed
# https://docs.sigstore.dev/cosign/installation/

# Generate cosign keypair (you'll be prompted for a password)
cosign generate-key-pair k8s://tekton-chains/signing-secrets

# Save public key to repository
kubectl get secret signing-secrets -n tekton-chains \
    -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub

# Restart controller
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
```

**For Production** (use Fulcio for keyless signing):
```bash
# Enable Fulcio for keyless signing with OIDC identity
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "signers.x509.fulcio.enabled": "true",
    "signers.x509.fulcio.address": "https://fulcio.sigstore.dev",
    "signers.x509.fulcio.oidc.issuer": "https://oauth2.sigstore.dev/auth",
    "transparency.enabled": "true",
    "transparency.url": "https://rekor.sigstore.dev"
  }
}'
```

**Verify Keys Exist**:
```bash
kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data}' | jq 'keys'
# Should show: ["cosign.key", "cosign.password", "cosign.pub"]
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
