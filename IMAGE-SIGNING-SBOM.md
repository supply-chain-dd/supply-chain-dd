# Image Signing and SBOM Generation with Tekton Chains

## Quick Answer

**Q: Can Tekton Chains generate signatures and SBOMs for images from push-build-pipeline?**

**A: YES — use the Chains-compatible pipeline.**

The `push-build-pipeline-with-chains` pipeline pushes the image with `IMAGE_DIGEST` and `IMAGE_URL` results so Tekton Chains signs it automatically.
The pipeline generates an SPDX JSON SBOM with Trivy (no Tekton Chains envolved) and attaches it as an in-toto attestation using cosign.

---

## Current State

### What Works (After `make setup-challenge2-tekton`)

1. **Image Signing** — Tekton Chains detects the `IMAGE_URL` + `IMAGE_DIGEST` results and signs the image with cosign
2. **SLSA Provenance** — Chains generates an in-toto SLSA Provenance attestation (stored as `<image>.att`)
3. **SBOM Attestation** — The `generate-and-attest-sbom` task creates an SPDX JSON SBOM with Trivy and attaches it via `cosign attest --type spdxjson`
4. **PipelineRun / TaskRun Attestations** — Chains generates in-toto provenance for both

### Conforma Policy Validation

Conforma (`ec validate image`) is **not run inside the pipeline** because Tekton Chains
generates PipelineRun attestations only AFTER the pipeline completes. Rules like
`attestation_type.pipelinerun_attestation_found` and `slsa_source_correlated.*` cannot
be satisfied from within the pipeline. Run `ec` from the command line after the pipeline
finishes — see [TEKTON-CHAINS.md](TEKTON-CHAINS.md) for examples.

---

## How to Use

```bash
# 1. Install Tekton Chains (if not done)
make setup-tektonchains

# 2. Deploy challenge 2 resources (tasks, secrets, pipeline)
make setup-challenge2-tekton

# 3. Trigger the Chains-compatible pipeline
make trigger-challenge2-build-with-chains

# 4. Verify image was signed
kubectl get taskruns -n ctf-challenge \
  -l tekton.dev/pipelineTask=push-container-image \
  -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'
```

**What you get**:
- Image signature (`.sig` tag in registry)
- SLSA Provenance attestation (`.att` tag in registry)
- SBOM attestation (cosign in-toto, predicateType `https://spdx.dev/Document`)
- PipelineRun + TaskRun provenance

---

## What Gets Signed and Where

### Artifacts Generated

When using `push-build-pipeline-with-chains`:

```
+-------------------------------------------------------------+
| OCI Registry: registry.registry.svc.cluster.local:5000      |
+-------------------------------------------------------------+
|                                                              |
|  recipe-api:v1.0                     (Container Image)       |
|  +- sha256:abc123...                 (Image Manifest)        |
|  +- sha256:abc123.sig                (Image Signature)       |
|  +- sha256:abc123.att                (SLSA Provenance +      |
|  |                                    SBOM Attestation)       |
|                                                              |
+-------------------------------------------------------------+
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
# Verify using Tekton Chains signing key
cosign verify \
  --insecure-ignore-tlog \
  --key cosign.pub \
  --registry-cacert=setup/certs/registry.crt \
  localhost:30000/recipe-api:v1.0

# Verify SBOM attestation
cosign verify-attestation \
  --insecure-ignore-tlog \
  --key cosign.pub \
  --type spdxjson \
  --registry-cacert=setup/certs/registry.crt \
  localhost:30000/recipe-api:v1.0

# Verify SLSA provenance attestation
cosign verify-attestation \
  --insecure-ignore-tlog \
  --key cosign.pub \
  --type https://slsa.dev/provenance/v0.2 \
  --registry-cacert=setup/certs/registry.crt \
  localhost:30000/recipe-api:v1.0
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
    - name: IMAGE_DIGEST          # Added
      description: Digest of pushed image
    - name: IMAGE_URL             # Added
      description: Full URL of image
  steps:
    - name: push-image
      args:
        - --destination=$(params.registry-url)/$(params.image-name):$(params.image-tag)
        - --digest-file=/tekton/results/IMAGE_DIGEST  # Added
    
    - name: write-image-url       # Added
      script: |
        echo -n "$(params.registry-url)/$(params.image-name):$(params.image-tag)" \
          > /tekton/results/IMAGE_URL
```

**Key Changes**:
1. Added `results` section declaring `IMAGE_DIGEST` and `IMAGE_URL` **only to push task**
2. Kaniko writes digest to `/tekton/results/IMAGE_DIGEST` via `--digest-file` flag
3. New step writes full image URL to `/tekton/results/IMAGE_URL`
4. Tekton Chains detects these results and triggers signing

**Important**: The `build-container-image` task does NOT output IMAGE results because:
- It uses `--no-push` (image never goes to registry)
- Only saves image as local tarball
- If it output IMAGE_URL without registry prefix, Chains would try to pull from Docker Hub

Only tasks that **push to a registry** should output IMAGE results.

---

## Comparison: Standard vs Chains-Compatible Pipeline

| Capability | push-build-pipeline | push-build-pipeline-with-chains |
|-----------|---------------------|--------------------------------|
| **Build image** | Yes | Yes |
| **Push to registry** | Yes | Yes |
| **PipelineRun provenance** | Yes (if Chains installed) | Yes |
| **TaskRun provenance** | Generic only | Full |
| **Image signature** | No | Yes |
| **SBOM (SPDX JSON)** | No | Yes (Trivy + cosign attest) |
| **IMAGE_DIGEST result** | No | Yes |
| **IMAGE_URL result** | No | Yes |
| **Cosign verification** | No | Yes |

---

## FAQ

**Q: Do I need to switch tasks for the attack to work?**  
A: No, the container layer leak attack works with both versions. The Chains-compatible version adds security features but doesn't prevent the attack.

**Q: Will signed images contain leaked secrets?**  
A: Yes! Signing verifies **authenticity**, not **security**. A properly signed image can still have vulnerabilities or leaked secrets.

**Q: Can I use both pipeline versions?**  
A: Yes, but not simultaneously. Use the appropriate Make target:
```bash
# Standard pipeline (no supply chain security)
make trigger-challenge2-build

# Chains-compatible pipeline (signing + SBOM)
make trigger-challenge2-build-with-chains
```

**Q: Why isn't Conforma run inside the pipeline?**  
A: Tekton Chains generates PipelineRun attestations only after the pipeline completes. Policy rules like `attestation_type.pipelinerun_attestation_found` and `slsa_source_correlated.*` cannot be satisfied from within the pipeline. Run `ec validate image` from the command line after the pipeline finishes.

**Q: What about SBOMs for the base image (golang:1.25-alpine)?**  
A: Tekton Chains only signs images **built by the pipeline**, not pulled base images. For base image verification, use tools like Cosign, Syft, or Grype.

---

## Summary

### After `make setup-challenge2-tekton` + `make trigger-challenge2-build-with-chains`

- Image signature (cosign, `.sig` tag)
- SLSA Provenance attestation (Tekton Chains, `.att` tag)
- SBOM attestation (Trivy SPDX JSON + cosign attest)
- PipelineRun + TaskRun provenance (in-toto format)

### Documentation
- Full details: [TEKTON-CHAINS.md](TEKTON-CHAINS.md)
- Task comparison: [challenges/challenge2/tekton/tasks/README.md](challenges/challenge2/tekton/tasks/README.md)
