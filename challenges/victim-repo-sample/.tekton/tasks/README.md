# Challenge 2 - Tekton Tasks

This directory contains two versions of the build tasks for Challenge 2:

## Task Files

### `build-tasks.yaml` (Standard)
- **Purpose**: Basic container image building and pushing
- **Tekton Chains Support**: Generates PipelineRun provenance only
- **Image Signing**: ❌ Not supported
- **SBOM Generation**: ❌ Not supported

**Use this for**: Learning about the container layer leak attack without supply chain security features.

### `build-tasks-with-chains.yaml` (Enhanced)
- **Purpose**: Container building with full Tekton Chains integration
- **Tekton Chains Support**: Full integration
  - ✅ PipelineRun provenance
  - ✅ TaskRun provenance  
  - ✅ Image signing
  - ✅ SBOM generation (if configured)
- **Key Additions**:
  - Tasks output `IMAGE_DIGEST` result
  - Tasks output `IMAGE_URL` result
  - Kaniko configured with `--digest-file` flag

**Use this for**: Learning about supply chain security with automatic attestation and signing.

## Switching Between Versions

### Use Standard Tasks (Default)
```bash
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks.yaml
make trigger-challenge2-build
```

### Use Chains-Compatible Tasks
```bash
# Install Tekton Chains first
make setup-tektonchains

# Apply enhanced tasks
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml

# Trigger build
make trigger-challenge2-build

# Verify image signing
kubectl get taskruns -n ci \
  -l tekton.dev/pipelineTask=push-container-image \
  -o jsonpath='{.items[*].metadata.annotations.chains\.tekton\.dev/signed}'
```

## Differences Summary

| Feature | build-tasks.yaml | build-tasks-with-chains.yaml |
|---------|-----------------|------------------------------|
| Container build | ✅ | ✅ |
| Registry push | ✅ | ✅ |
| PipelineRun provenance | ✅ (if Chains installed) | ✅ (if Chains installed) |
| TaskRun provenance | ❌ | ✅ (if Chains installed) |
| Image signing | ❌ | ✅ (if Chains installed) |
| SBOM generation | ❌ | ✅ (if Chains configured) |
| IMAGE_DIGEST result | ❌ | ✅ |
| IMAGE_URL result | ❌ | ✅ |

## Verifying Signatures

After using the Chains-compatible tasks:

```bash
# Get the latest TaskRun
TASKRUN=$(kubectl get taskruns -n ci \
  -l tekton.dev/pipelineTask=push-container-image \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)

# Check if it was signed
kubectl get $TASKRUN -n ci \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'

# View image digest
kubectl get $TASKRUN -n ci \
  -o jsonpath='{.status.taskResults[?(@.name=="IMAGE_DIGEST")].value}'

# Verify signature with cosign (requires cosign CLI)
cosign verify --insecure-ignore-tlog \
  --key k8s://tekton-chains/signing-secrets \
  --registry-cacert=setup/certs/registry.crt \
 registry.sc.local:30443/recipe-api:latest
```

## Attack Scenario Impact

**Standard Tasks**: The container layer leak attack works the same way - leaked `.git` directory in image layers exposes secrets.

**Chains-Compatible Tasks**: The attack still works, BUT:
- The malicious image will be cryptographically signed
- The signature creates an audit trail
- Detection tools can verify that the signed image contains leaked secrets
- This demonstrates that signing alone doesn't prevent all attacks

This illustrates an important supply chain security lesson: **signatures verify authenticity, not security**. A properly signed image can still contain vulnerabilities or leaked secrets!
