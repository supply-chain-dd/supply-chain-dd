# Challenge 2 - Tekton Tasks

This directory contains three task files for Challenge 2:

## Task Files

### `build-tasks.yaml` (Standard)

Contains the basic build pipeline tasks:
- `build-container-image` — builds the image with kaniko (no push)
- `push-container-image` — pushes the image to the registry

**Tekton Chains support**: Generates PipelineRun provenance only (no image signing or attestation).

**Use this for**: Running the standard `push-build-pipeline` to learn about the container layer leak attack without supply chain security features.

### `build-tasks-with-chains.yaml` (Chains + SBOM)

Contains tasks that extend the standard pipeline with supply chain security:

#### `push-container-image-with-chains`
Extends `push-container-image` with two Tekton task results:
- `IMAGE_URL` — full registry path of the pushed image
- `IMAGE_DIGEST` — sha256 digest written by kaniko via `--digest-file`

Tekton Chains watches for completed TaskRuns that emit **both** of these results, then automatically:
1. Signs the image with cosign (stores signature as `<image>.sig` in the registry)
2. Generates a SLSA Provenance in-toto attestation (stored as `<image>.att`)

**Important design**: The `build-container-image` task does NOT output IMAGE results because it uses `--no-push` (tarball only). If it did, Tekton Chains would attempt to pull an unregistered image and fail.

#### `generate-sbom`
Generates an SPDX JSON SBOM for the pushed container image using Trivy, then
attaches it to the image via OCI referrers API using oras.

- **Step 1 (generate-sbom)**: Runs `trivy image --format spdx-json` against the
  pushed image. Normalizes Trivy's output to comply with SPDX 2.3 (fixes
  hyphenated enum values like `OPERATING-SYSTEM` → `OPERATING_SYSTEM`).
- **Step 2 (attach-sbom)**: Downloads oras, then runs `oras attach` with artifact
  type `application/spdx+json` to attach the SBOM as an OCI referrer.

The SBOM file is shared between steps via an emptyDir volume.

Prerequisites:
- `registry-docker-config` Secret (for registry authentication)
- `registry-ca-cert` ConfigMap (for TLS trust)

#### `wait-for-chains` (not used by the current pipeline)
Inserts a configurable delay (default 45 s) after the image push. Available for
pipelines that need to wait for Chains to finish signing before proceeding to a
verification step.

#### `verify-with-conforma` (not used by the current pipeline)
Validates a container image against Conforma (Enterprise Contract) policy using the `ec` CLI.
Not included in the pipeline because Tekton Chains generates PipelineRun attestations only
after the pipeline completes — rules like `attestation_type.pipelinerun_attestation_found`
cannot be satisfied from within the pipeline. Run `ec` from the command line instead.

### `verify-source-task.yaml` (Source Verification + VSA)

Contains two tasks for SLSA Source verification:

#### `verify-source-provenance`
Runs as the first task in `push-build-pipeline-with-chains`, before `git-clone`.
Validates that the incoming repository URL matches a trusted repository and that the
commit SHA is reachable from a protected branch (default: `main`).

On success, generates an unsigned Source Verification Summary Attestation (VSA) following
the in-toto Statement v1 format with predicateType `https://slsa.dev/verification_summary/v1`,
claiming `SLSA_SOURCE_LEVEL_1`. The VSA JSON is emitted as a task result for downstream use.

No signing is performed — Tekton Chains handles all cryptographic signing.

#### `create-source-vsa`
Runs after `push-container-image`, in parallel with `generate-sbom`.
Reads the unsigned Source VSA from a task param (routed from `verify-source-provenance`
via pipeline result wiring) and attaches it to the pushed container image using the
OCI referrers API via `oras attach`.

The VSA artifact digest is output as a result (`VSA_DIGEST`) for potential inclusion
in Tekton Chains' signed provenance attestation.

Prerequisites:
- `registry-docker-config` Secret (for registry authentication)
- `registry-ca-cert` ConfigMap (for TLS trust)

### `supporting-tasks.yaml`

The `git-clone` task emits four results consumed by the chains pipeline:
- `url` + `commit` — used by Conforma's `provenance_materials.git_clone_task_found` rule
- `CHAINS-GIT_URL` + `CHAINS-GIT_COMMIT` — Tekton Chains type hints that populate the
  SLSA provenance `materials[]` section with `{"uri":"git+<url>","digest":{"sha1":"<sha>"}}`

## Pipeline this supports

`build-tasks-with-chains.yaml` is consumed by `push-build-pipeline-with-chains`:

```
verify-source-provenance                        <- validates repo URL + branch containment
  +-- git-clone                                 <- emits url + commit results
       +-- build-go-app
            +-- run-quality-checks
                 +-- build-container-image
                      +-- push-container-image-with-chains   <- emits IMAGE_URL + IMAGE_DIGEST
                           +-- create-source-vsa             <- attaches unsigned Source VSA via OCI referrers
                           +-- generate-sbom                 <- Trivy SBOM + oras attach
```

## Switching Between Versions

### Standard pipeline (no supply chain security)
```bash
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks.yaml
make trigger-challenge2-build
```

### Chains + SBOM pipeline
```bash
# Prerequisites
make setup-tektonchains        # Install and configure Tekton Chains
make setup-challenge2-tekton   # Creates secrets and deploys tasks

# Trigger
make trigger-challenge2-build-with-chains

# Monitor
tkn pipelinerun logs -f -n ci

# After the pipeline finishes, validate with Conforma:
SSL_CERT_FILE=certs/registry.crt \
ec validate image \
  --image registry.sc.local:30443/recipe-api:v1.0@sha256:<digest> \
  --public-key cosign.pub \
  --policy '{"sources":[{"name":"sc-minimal","policy":["github.com/conforma/policy//policy/lib","github.com/conforma/policy//policy/release"],"config":{"include":["@minimal"],"exclude":["base_image_registries.base_image_info_found","cve.cve_results_found"]}}]}' \
  --ignore-rekor --output text
```

## Differences Summary

| Feature | build-tasks.yaml | build-tasks-with-chains.yaml |
|---------|-----------------|------------------------------|
| Container build | Yes | Yes |
| Registry push | Yes | Yes |
| PipelineRun provenance | Yes (if Chains installed) | Yes (if Chains installed) |
| TaskRun provenance | No | Yes (if Chains installed) |
| Image signing | No | Yes (if Chains installed) |
| IMAGE_DIGEST result | No | Yes |
| IMAGE_URL result | No | Yes |
| SBOM generation (Trivy) | No | Yes (SPDX JSON) |
| SBOM attachment (oras, OCI referrer) | No | Yes |
| Source verification (SLSA) | No | Yes (verify-source-provenance) |
| Source VSA (OCI referrer) | No | Yes (create-source-vsa) |

## Verifying Signatures

After running the Chains-compatible pipeline:

```bash
# Check that the push TaskRun was signed by Chains
TASKRUN=$(kubectl get taskruns -n ci \
  -l tekton.dev/pipelineTask=push-container-image \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)

kubectl get $TASKRUN -n ci \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'
# Expected: "true"

# View the image digest from the task result
kubectl get $TASKRUN -n ci \
  -o jsonpath='{.status.taskResults[?(@.name=="IMAGE_DIGEST")].value}'

# Verify cosign signature from the host (requires cosign CLI)
cosign verify --insecure-ignore-tlog \
  --key cosign.pub \
  --registry-cacert certs/registry.crt \
  registry.sc.local:30443/recipe-api:v1.0

# List OCI referrers (SBOM + Source VSA)
oras discover registry.sc.local:30443/recipe-api:v1.0 \
  --registry-config ~/.docker/config.json \
  --ca-file certs/registry.crt
```

## Attack Scenario Impact

**Standard Tasks**: The container layer leak attack works as designed — the `.git` directory is present in image layers and exposes secrets.

**Chains-Compatible Tasks**: The attack still works, but:
- The source is verified against a trusted repository before building
- The image is cryptographically signed, creating an audit trail
- The SLSA Provenance attestation records exactly what was built and how
- The SBOM documents every package in the image
- A Source VSA records source verification status as an OCI referrer
- Detection tools can verify that the signed image contains leaked secrets

This illustrates an important supply chain security principle: **signatures verify authenticity, not security**. A properly signed image can still contain vulnerabilities or leaked secrets. Provenance tells you *where* an image came from, not *what's inside it*.
