# Challenge 2 - Tekton Tasks

This directory contains two task bundles for Challenge 2:

## Task Files

### `build-tasks.yaml` (Standard)

Contains the basic build pipeline tasks:
- `build-container-image` — builds the image with kaniko (no push)
- `push-container-image` — pushes the image to the registry

**Tekton Chains support**: Generates PipelineRun provenance only (no image signing or attestation).

**Use this for**: Running the standard `push-build-pipeline` to learn about the container layer leak attack without supply chain security features.

### `build-tasks-with-chains.yaml` (Chains + Conforma)

Contains three tasks that extend the standard pipeline with supply chain security:

#### `push-container-image-with-chains`
Extends `push-container-image` with two Tekton task results:
- `IMAGE_URL` — full registry path of the pushed image
- `IMAGE_DIGEST` — sha256 digest written by kaniko via `--digest-file`

Tekton Chains watches for completed TaskRuns that emit **both** of these results, then automatically:
1. Signs the image with cosign (stores signature as `<image>.sig` in the registry)
2. Generates a SLSA Provenance in-toto attestation (stored as `<image>.att`)

**Important design**: The `build-container-image` task does NOT output IMAGE results because it uses `--no-push` (tarball only). If it did, Tekton Chains would attempt to pull an unregistered image and fail.

#### `wait-for-chains`
Inserts a configurable delay (default 45 s) between the image push and the Conforma validation step. Tekton Chains signs images asynchronously after TaskRun completion; this task gives Chains time to finish before the policy validator runs.

#### `verify-with-conforma`
Validates the pushed image against Conforma (Enterprise Contract) policy using the `ec` CLI:
- Downloads `ec` binary from GitHub releases (public, no authentication required)
- Parses the `IMAGES` ApplicationSnapshot JSON to extract the container image reference
- Runs `ec validate image` with the cosign public key and SLSA policy checks
- In **non-strict mode** (`STRICT=false`): reports violations but lets the pipeline continue — useful for learning/exploration (Challenge 2)
- In **strict mode** (`STRICT=true`): fails the pipeline on any policy violation — used in Challenge 3

Parameter names deliberately mirror the official `verify-enterprise-contract` task from
`quay.io/redhat-appstudio-tekton-catalog/task-verify-enterprise-contract` so this task can be
swapped to the official bundle in an environment with Red Hat registry credentials.

**Why not the official OCI bundle?**
The official bundle's step image (`registry.redhat.io/rhtas/ec-rhel9`) requires Red Hat registry
credentials that are not available on a bare KinD cluster. This inline task is functionally
equivalent and uses only public images (`alpine:3.18`).

## Pipeline this supports

`build-tasks-with-chains.yaml` is consumed by `push-build-pipeline-with-chains`:

```
clone-repo
  └─ build-go-app
       └─ run-quality-checks
            └─ build-container-image
                 └─ push-container-image-with-chains   ← emits IMAGE_URL + IMAGE_DIGEST
                      └─ wait-for-chains               ← sleep while Chains signs
                           └─ verify-enterprise-contract ← ec validate image
```

## Switching Between Versions

### Standard pipeline (no supply chain security)
```bash
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks.yaml
make trigger-challenge2-build
```

### Chains + Conforma pipeline
```bash
# Prerequisites
make setup-tektonchains        # Install and configure Tekton Chains
make setup-challenge2-tekton   # Creates cosign-public-key Secret and deploys tasks

# Trigger
make trigger-challenge2-build-with-chains

# Monitor
tkn pipelinerun logs -f -n ctf-challenge
```

## Differences Summary

| Feature | build-tasks.yaml | build-tasks-with-chains.yaml |
|---------|-----------------|------------------------------|
| Container build | ✅ | ✅ |
| Registry push | ✅ | ✅ |
| PipelineRun provenance | ✅ (if Chains installed) | ✅ (if Chains installed) |
| TaskRun provenance | ❌ | ✅ (if Chains installed) |
| Image signing | ❌ | ✅ (if Chains installed) |
| IMAGE_DIGEST result | ❌ | ✅ |
| IMAGE_URL result | ❌ | ✅ |
| Conforma policy validation | ❌ | ✅ |
| STRICT enforcement | ❌ | Configurable (false = log, true = fail) |

## Verifying Signatures

After running the Chains-compatible pipeline:

```bash
# Check that the push TaskRun was signed by Chains
TASKRUN=$(kubectl get taskruns -n ctf-challenge \
  -l tekton.dev/pipelineTask=push-container-image \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)

kubectl get $TASKRUN -n ctf-challenge \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'
# Expected: "true"

# View the image digest from the task result
kubectl get $TASKRUN -n ctf-challenge \
  -o jsonpath='{.status.taskResults[?(@.name=="IMAGE_DIGEST")].value}'

# Verify cosign signature from the host (requires cosign CLI)
cosign verify --insecure-ignore-tlog \
  --key cosign.pub \
  --insecure-skip-tlog-verify \
  --ca-cert certs/registry.crt \
  localhost:30000/recipe-api:v1.0

# Validate with ec CLI from the host
ec validate image \
  --image localhost:30000/recipe-api:v1.0@<digest> \
  --public-key cosign.pub \
  --policy '{"sources":[{"name":"minimal","policy":["github.com/conforma/policy//policy/lib","github.com/conforma/policy//policy/release"],"config":{"include":["@minimal"],"exclude":[]}}]}' \
  --ignore-rekor \
  --output text
```

## Attack Scenario Impact

**Standard Tasks**: The container layer leak attack works as designed — the `.git` directory is present in image layers and exposes secrets.

**Chains-Compatible Tasks**: The attack still works, but:
- The image is cryptographically signed, creating an audit trail
- The SLSA Provenance attestation records exactly what was built and how
- Detection tools can verify that the signed image contains leaked secrets
- The Conforma validation step will detect the secrets (once a secrets policy is added)

This illustrates an important supply chain security principle: **signatures verify authenticity, not security**. A properly signed image can still contain vulnerabilities or leaked secrets. Provenance tells you *where* an image came from, not *what's inside it*.
