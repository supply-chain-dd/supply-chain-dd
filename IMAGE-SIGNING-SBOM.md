# Image Signing and SBOM Generation with Tekton Chains

## Quick Answer

**Q: Can Tekton Chains generate signatures and SBOMs for images from push-build-pipeline?**

**A: YES, but requires task updates.** 

The current configuration enables signing, but the tasks need to output `IMAGE_DIGEST` and `IMAGE_URL` results for Chains to detect and sign the images.

---

## Current State

### ✅ What Works Now (After `make setup-tektonchains`)

1. **PipelineRun Attestations** - Automatically generated for all pipeline runs
   - Format: in-toto (AMPEL/Conforma compatible) 
   - Storage: OCI registry
   - Includes full execution provenance

2. **TaskRun Attestations** - Generated for individual tasks
   - Same format and storage as PipelineRuns
   - Documents what each task did

3. **Configuration Enabled**:
   - `artifacts.oci.format: simplesigning` ✅
   - `artifacts.oci.storage: oci` ✅
   - `artifacts.oci.signer: x509` ✅

### ❌ What Doesn't Work Yet

1. **Image Signing** - Not working with current tasks
   - **Why**: Tasks don't output `IMAGE_DIGEST` or `IMAGE_URL` results
   - **Impact**: Chains can't detect which images to sign

2. **SBOM Generation** - Not configured
   - **Why**: Requires additional configuration and tooling
   - **Impact**: No software bill of materials generated

---

## How to Enable Full Support

### Option 1: Use Enhanced Tasks (Recommended)

```bash
# 1. Install Tekton Chains (if not done)
make setup-tektonchains

# 2. Apply Chains-compatible tasks
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml

# 3. Trigger pipeline
make trigger-challenge2-build

# 4. Verify image was signed
kubectl get taskruns -n ctf-challenge \
  -l tekton.dev/pipelineTask=push-container-image \
  -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'
```

**What you get**:
- ✅ PipelineRun provenance
- ✅ TaskRun provenance
- ✅ **Image signature**
- ✅ IMAGE_DIGEST and IMAGE_URL in results
- ⚠️ SBOM (requires additional config - see below)

### Option 2: Enable SBOM Generation

```bash
# Configure Chains for SBOM
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "artifacts.oci.format": "simplesigning",
    "artifacts.sbom.format": "cyclonedx",
    "artifacts.sbom.enabled": "true"
  }
}'

# Restart controller
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
kubectl rollout status deployment tekton-chains-controller -n tekton-chains

# Now run pipeline with Chains-compatible tasks
make trigger-challenge2-build
```

---

## What Gets Signed and Where

### Artifacts Generated

When using `build-tasks-with-chains.yaml`:

```
┌─────────────────────────────────────────────────────────────┐
│ OCI Registry: registry.registry.svc.cluster.local:5000      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  📦 recipe-api:latest                (Container Image)      │
│  ├─ sha256:abc123...                 (Image Manifest)       │
│  ├─ 🔏 sha256:abc123.sig             (Image Signature)      │
│  ├─ 📄 sha256:abc123.att             (SBOM Attestation)     │
│  └─ 📜 sha256:abc123.provenance      (Build Provenance)     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Signature Format

Tekton Chains uses **simple signing** (similar to Cosign v1):
- Signature stored as OCI artifact
- Signed with x509 keys (self-signed by default)
- Compatible with Cosign verification
- Can be configured to use Fulcio/Rekor (Sigstore)

---

## Verification Examples

### Check if Image Was Signed

```bash
# Get latest TaskRun that pushed an image
TASKRUN=$(kubectl get taskruns -n ctf-challenge \
  -l tekton.dev/pipelineTask=push-container-image \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)

# Check signature status
kubectl get $TASKRUN -n ctf-challenge \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'
# Output: "true" if signed

# View image digest
kubectl get $TASKRUN -n ctf-challenge \
  -o jsonpath='{.status.taskResults[?(@.name=="IMAGE_DIGEST")].value}'
# Output: sha256:abc123...
```

### Verify Signature with Cosign

```bash
# Install cosign (if needed)
# See: https://docs.sigstore.dev/cosign/installation/

# Verify using Tekton Chains signing key
cosign verify \
  --insecure-ignore-tlog \
  --key k8s://tekton-chains/signing-secrets \
  registry.registry.svc.cluster.local:5000/recipe-api:latest

# Expected output:
# Verification for registry.registry.svc.cluster.local:5000/recipe-api:latest --
# The following checks were performed on each of these signatures:
#   - The cosign claims were validated
#   - The signatures were verified against the specified public key
```

### View SBOM (if enabled)

```bash
# Download SBOM attestation
cosign download attestation \
  registry.registry.svc.cluster.local:5000/recipe-api:latest \
  | jq -r '.payload' | base64 -d | jq

# Or use syft directly
syft registry.registry.svc.cluster.local:5000/recipe-api:latest -o json
```

---

## Task Changes Explained

### What Changed in build-tasks-with-chains.yaml

#### Before (build-tasks.yaml):
```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: push-container-image
spec:
  # No results section
  steps:
    - name: push-image
      args:
        - --destination=$(params.registry-url)/$(params.image-name):$(params.image-tag)
        # No digest-file
```

#### After (build-tasks-with-chains.yaml):
```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: push-container-image
spec:
  results:
    - name: IMAGE_DIGEST          # ← Added
      description: Digest of pushed image
    - name: IMAGE_URL             # ← Added
      description: Full URL of image
  steps:
    - name: push-image
      args:
        - --destination=$(params.registry-url)/$(params.image-name):$(params.image-tag)
        - --digest-file=/tekton/results/IMAGE_DIGEST  # ← Added
    
    - name: write-image-url       # ← Added
      script: |
        echo -n "$(params.registry-url)/$(params.image-name):$(params.image-tag)" \
          > /tekton/results/IMAGE_URL
```

**Key Changes**:
1. Added `results` section declaring `IMAGE_DIGEST` and `IMAGE_URL`
2. Kaniko writes digest to `/tekton/results/IMAGE_DIGEST` via `--digest-file` flag
3. New step writes full image URL to `/tekton/results/IMAGE_URL`
4. Tekton Chains detects these results and triggers signing

---

## Comparison: Standard vs Chains-Compatible Tasks

| Capability | build-tasks.yaml | build-tasks-with-chains.yaml |
|-----------|------------------|------------------------------|
| **Build image** | ✅ | ✅ |
| **Push to registry** | ✅ | ✅ |
| **PipelineRun provenance** | ✅ | ✅ |
| **TaskRun provenance** | ⚠️ Generic only | ✅ Full |
| **Image signature** | ❌ | ✅ |
| **SBOM** | ❌ | ✅ (if configured) |
| **IMAGE_DIGEST result** | ❌ | ✅ |
| **IMAGE_URL result** | ❌ | ✅ |
| **Cosign verification** | ❌ | ✅ |
| **AMPEL policy enforcement** | ⚠️ Limited | ✅ Full |

---

## Integration with AMPEL

With image signing enabled, you can enforce policies like:

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: require-signed-images
spec:
  checks:
    - name: verify-image-signature
      condition: |
        image.signatures.exists(sig => 
          sig.issuer == "tekton-chains" &&
          sig.verified == true
        )
      severity: CRITICAL
      message: "All deployed images must be signed by Tekton Chains"
```

---

## FAQ

**Q: Do I need to switch tasks for the attack to work?**  
A: No, the container layer leak attack works with both versions. The Chains-compatible version adds security features but doesn't prevent the attack.

**Q: Will signed images contain leaked secrets?**  
A: Yes! Signing verifies **authenticity**, not **security**. A properly signed image can still have vulnerabilities or leaked secrets.

**Q: Can I use both task versions?**  
A: Yes, but not simultaneously. Apply one version at a time:
```bash
# Switch to Chains version
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml

# Switch back to standard
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks.yaml
```

**Q: What about SBOMs for the base image (golang:1.25-alpine)?**  
A: Tekton Chains only signs/generates SBOMs for images **built by the pipeline**, not pulled base images. For base image verification, use tools like:
- Cosign to verify base image signatures
- Syft to generate SBOMs for base images
- Grype to scan for vulnerabilities

---

## Summary

### Current Setup (After `make setup-tektonchains`)
✅ PipelineRun attestations  
✅ TaskRun attestations  
✅ OCI storage  
✅ in-toto format (AMPEL/Conforma compatible)  
❌ Image signing (needs task update)  
❌ SBOM generation (needs configuration)

### To Enable Full Support
```bash
# 1. Setup Chains
make setup-tektonchains

# 2. Apply enhanced tasks
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml

# 3. (Optional) Enable SBOM
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {"artifacts.sbom.enabled": "true"}
}'
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains

# 4. Run pipeline
make trigger-challenge2-build

# 5. Verify
kubectl get taskruns -n ctf-challenge \
  -l tekton.dev/pipelineTask=push-container-image \
  -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'
```

### Documentation
- Full details: [TEKTON-CHAINS.md](TEKTON-CHAINS.md)
- Task comparison: [challenges/challenge2/tekton/tasks/README.md](challenges/challenge2/tekton/tasks/README.md)
