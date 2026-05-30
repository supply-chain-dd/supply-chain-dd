# Security Guide: Leaked Secrets in Container Images

This guide demonstrates how to **detect and prevent** secret leaks in container image layers — the vulnerability exploited in Challenge 2.

## Learning Objectives

After completing this guide, you will understand how to:

1. **Prevent secrets from entering images** using `.dockerignore`, multi-stage builds, and BuildKit secrets
2. **Scan built images** for leaked secrets and vulnerabilities using Trivy
3. **Attach scan results** to images as signed attestations (cosign + in-toto)
4. **Enforce policies** on scan results using Conforma (Enterprise Contract)
5. **Block deployment** of non-compliant images using admission controllers

---

## Interactive Demos

This challenge includes three demo-magic scripts that walk through remediation and defense interactively. Each can be run standalone after the environment is set up (`make setup && make setup-challenge2-tekton`).

| Script | What It Demonstrates | Guide Sections |
|--------|---------------------|----------------|
| `./filter-repo-demo.sh` | Using `git-filter-repo` to permanently remove `.env.production` from git history | Section 1.5 |
| `./defense-demo.sh` | End-to-end defense: Dockerfile fix (multi-stage + `.dockerignore`), Trivy Rego policy scan, scanner limitations, image purge, webhook-triggered secure pipeline, and verification | Phases 1, 2, 5 |
| `./tektonchains-demo.sh` | Tekton Chains installation, configuration, signing keys, pipeline execution, cosign verification of signatures and SLSA provenance | Phase 3 |

> **Prerequisites**: `defense-demo.sh` deploys a secure pipeline and triggers it via webhook. `keyless-signing-demo.sh` requires `cosign` installed and the local Sigstore stack deployed (`make setup-sigstore-local`).

---

## Phase 1: Quick Wins — Preventing Secrets at Build Time

These changes stop secrets from entering image layers in the first place. They require no additional tooling — just better Dockerfile practices.

### 1.1 Add a `.dockerignore` File

The single most impactful change. Without `.dockerignore`, `COPY . .` sends **every file** to the build daemon — including `.git`, `.env`, SSH keys, and credentials.

**Allowlist pattern** (recommended — ignore everything, include only what's needed):

```dockerignore
# Ignore everything
*
# Include only what the build needs
!main.go
!go.mod
!go.sum
!cmd/
!internal/
!pkg/
!scripts/quality-check/
```

This flips the default from "include everything" to "include nothing." Even if a developer adds a new secret file, it won't enter the build context unless explicitly allowed.

**Denylist pattern** (fallback — block known dangerous paths):

```dockerignore
# Version control (CRITICAL for Challenge 2)
.git
.gitignore
.gitattributes

# Secrets and credentials
.env
.env.*
!.env.example
*.pem
*.key
*.crt
*.p12
credentials/
secrets/
.aws/
.ssh/
.npmrc
kubeconfig
*credentials*.json
service-account*.json

# Docker/build files
Dockerfile*
docker-compose*
.dockerignore

# IDE, docs, tests
.idea/
.vscode/
*.md
docs/
**/test/
**/tests/
coverage/
```

The allowlist pattern is strictly stronger: it blocks unknown files by default, whereas the denylist only blocks what you remembered to list.

### 1.2 Use Multi-Stage Builds

Multi-stage builds separate the build environment (which may need secrets or source history) from the final runtime image. Only explicitly copied artifacts appear in the final image:

```dockerfile
# Stage 1: Build — may contain .git, .env, credentials
FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o recipe-api main.go

# Stage 2: Runtime — contains only the compiled binary
FROM alpine:3.20
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/recipe-api .
EXPOSE 8080
CMD ["./recipe-api"]
```

The `.git` directory, `.env` files, and source code exist only in the `builder` stage. The final image contains just the binary.

**Caveat**: Builder stage layers still exist in the local build cache. Anyone with access to the build machine can inspect them. Multi-stage builds protect the pushed image, not the build host.

### 1.3 Use BuildKit `--mount=type=secret` for Build-Time Credentials

If the build process itself needs credentials (e.g., private module registries, npm tokens), use BuildKit secret mounts instead of `COPY`:

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./

# Secret is mounted at /run/secrets/netrc ONLY during this RUN
# It is never written to any layer
RUN --mount=type=secret,id=netrc,target=/root/.netrc go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o recipe-api main.go

FROM alpine:3.20
RUN apk --no-cache add ca-certificates
COPY --from=builder /app/recipe-api .
CMD ["./recipe-api"]
```

```bash
podman build --secret id=netrc,src=$HOME/.netrc -t recipe-api .
```

The secret exists only for the duration of the `RUN` instruction. It is never committed to any layer and cannot be recovered from the image.

**Tool support:**

| Builder | `--mount=type=secret` | `.dockerignore` |
|---------|----------------------|-----------------|
| Docker (BuildKit) | Yes | Yes |
| Podman/Buildah | Yes | Yes |
| Kaniko | **No** (archived June 2025) | Yes (with bugs) |

Kaniko, used in this deep dive's pipeline, was archived by Google in June 2025 and never supported secret mounts. Teams using Kaniko should migrate to Buildah for Tekton pipelines. For this deep dive, `.dockerignore` and multi-stage builds are the available guardrails when using Kaniko.

### 1.4 The Patched Dockerfile

See [`tekton-patched/Dockerfile`](tekton-patched/Dockerfile) for a version that applies all three defenses. Compare it against the [vulnerable Dockerfile](../victim-repo-sample/Dockerfile) to understand the difference.

> The `./defense-demo.sh` (Phase 1, steps 2–8) demonstrates this end-to-end: it shows the vulnerable Dockerfile, runs the Trivy Rego scan to detect the anti-pattern, replaces the Dockerfile with a multi-stage build, adds the `.dockerignore` allowlist, commits the fix, and protects the main branch.

### 1.5 Remediation: Cleaning Secrets from Git History with `git-filter-repo`

When secrets have already been committed to a repository, prevention alone is not enough — the secrets persist in git history even after deletion. [`git-filter-repo`](https://github.com/newren/git-filter-repo) rewrites the entire repository history to permanently remove sensitive files.

**Why not `git rm` or `BFG Repo-Cleaner`?**

- `git rm` only removes the file from the working tree and creates a new commit. The file remains in all previous commits.
- `BFG Repo-Cleaner` is no longer maintained. `git-filter-repo` is the recommended replacement (endorsed by the Git project itself).

**Usage:**

```bash
# 1. Clone a fresh copy (filter-repo requires a full clone)
git clone http://gitea-server/org/repo.git
cd repo

# 2. Back up before rewriting (irreversible operation)
cd .. && tar -czf repo-backup.tar.gz repo && cd repo

# 3. Remove the sensitive file from ALL commits
git filter-repo --sensitive-data-removal --invert-paths --path .env.production

# 4. Verify the file is gone from history
git log --all --full-history -- .env.production
# (should return nothing)

# 5. Verify the secret content is gone
git log --all --full-history -S 'ARGOCD_AUTH_TOKEN' --oneline
# (should return nothing)

# 6. Force push the rewritten history
git push --force --mirror origin
```

**Flags explained:**

| Flag | Purpose |
|------|---------|
| `--sensitive-data-removal` | Optimized mode for credential cleanup — fetches all refs from origin first and provides follow-up instructions |
| `--invert-paths` | Invert the path selection (remove matching paths instead of keeping them) |
| `--path <file>` | Target file to remove from history |

**After the rewrite:**

- All commit hashes change (history is rewritten from the first affected commit onward)
- All collaborators must **re-clone** the repository — rebasing on rewritten history causes conflicts
- Contact server administrators to purge dangling objects and force garbage collection
- **Rebuild and re-push all container images** built from the old history — they still contain the secrets in their layers

**Interactive demo:**

```bash
./filter-repo-demo.sh
```

See also: [Red Hat LeakTK guide for git-filter-repo](https://source.redhat.com/departments/strategy_and_operations/it/it_information_security/leaktk/leaktk_guides/git_filter_repo)

---

## Phase 2: Scanning Built Images for Secrets and Vulnerabilities

Prevention is not enough — defense in depth requires **verifying** that images are clean after build. This section covers scanning the pushed image with Trivy.

### 2.1 Tool Comparison for Secret Detection

Not all scanners can detect secrets in container images. Here's what each tool actually does:

| Tool | Vuln Scanning | Secret Detection | SBOM Generation | Detects Deleted-Layer Secrets? |
|------|:------------:|:----------------:|:---------------:|:-----------------------------:|
| **Trivy** (`trivy image`) | Yes | Yes | Yes (SPDX, CycloneDX) | **No** — merged filesystem hides them |
| **TruffleHog** (`trufflehog docker`) | No | Yes (layer-by-layer) | No | **Partial** — scans each layer but cannot follow git history |
| **Trivy custom Rego** (`trivy config`) | No | No | No | **Yes** — catches the Dockerfile anti-pattern at source |
| **Kubescape** | Yes (via Grype) | **No** | No | No |
| **Syft** | No | No | Yes | No |
| **Grype** | Yes | No | No | No |
| **dive** | No | No | No | Yes (interactive layer inspection) |

> **Why do Trivy and TruffleHog both report zero secrets for Challenge 2?**
>
> The attack embeds credentials in **git history** (committed in one commit, deleted in the next). The `.git` directory is copied into an image layer via `COPY . .`, then "removed" via `RUN rm -rf .git`. Two things defeat scanners:
>
> 1. **Trivy** merges all layers into a union filesystem before scanning. The `rm -rf .git` creates a whiteout marker that hides `.git` in the merged view. Trivy sees zero `.git` content.
>
> 2. **TruffleHog** scans each layer individually (not merged), so it *does* see the `.git` directory in the COPY layer. However, the secret (`ARGO_CD_TOKEN`) only exists in git history (a prior commit) — it was deleted from the working tree before the image was built. TruffleHog scans file contents in each layer but does not reconstruct git history from `.git/objects`, so it misses the credential too.
>
> **The only reliable approach** is to prevent `.git` from entering the image in the first place (`.dockerignore`, multi-stage builds). As a detection backstop, a custom Trivy Rego policy can catch the dangerous `COPY . .` + `rm -rf .git` pattern at the Dockerfile level — see section 2.5.

For manual forensics after an incident, you can still extract and inspect individual layers:
- Manual layer extraction: `podman save | tar` then `trivy fs` on each layer
- Interactive inspection: `dive <image>` to browse individual layers
- The approach used in the deep dive challenge itself: extracting and inspecting layers

Despite the merged-filesystem limitation, Trivy image scanning is still valuable because:
1. It catches secrets that are **still present** in the final image (e.g., `.env` files not deleted)
2. It catches secrets in image config/metadata (`ENV` vars, build args)
3. It provides vulnerability and SBOM scanning in the same pass
4. Scan results can be attested and verified by policy engines

### 2.2 Scanning with Trivy (CLI)

> The `./defense-demo.sh` (Phase 2) demonstrates Trivy's limitation: scanning the vulnerable image with `trivy image --scanners secret` returns 0 secrets because the merged filesystem hides the deleted `.git` directory. It then purges the vulnerable image from the registry.

```bash
# Scan for secrets in the final image filesystem
trivy image --scanners secret registry.sc.local:30443/recipe-api:v1.0

# Scan for secrets in image config (ENV vars, build args)
trivy image --image-config-scanners secret registry.sc.local:30443/recipe-api:v1.0

# Combined: secrets + vulnerabilities + config secrets
trivy image \
  --scanners vuln,secret \
  --image-config-scanners secret \
  --format json \
  --output scan-results.json \
  registry.sc.local:30443/recipe-api:v1.0

# Generate vulnerability attestation predicate (cosign-vuln format)
trivy image \
  --scanners vuln,secret \
  --format cosign-vuln \
  --output vuln-predicate.json \
  registry.sc.local:30443/recipe-api:v1.0
```

### 2.3 Scanning Individual Layers (for Deleted Secrets)

To find secrets that were "deleted" in upper layers (the Challenge 2 attack), extract and scan each layer individually:

```bash
# Save image to tarball
podman save registry.sc.local:30443/recipe-api:v1.0 -o recipe-api.tar

# Extract layers
mkdir -p layers && cd layers
tar xf ../recipe-api.tar

# Scan each layer with trivy fs
for layer in $(find . -name "layer.tar" -o -name "*.tar.gz"); do
  echo "=== Scanning: $layer ==="
  tmpdir=$(mktemp -d)
  tar xf "$layer" -C "$tmpdir" 2>/dev/null
  trivy fs --scanners secret "$tmpdir"
  rm -rf "$tmpdir"
done
```

### 2.4 Tekton Task: Scan Image for Secrets and Vulnerabilities

The [`build-tasks-with-chains.yaml`](tekton/tasks/build-tasks-with-chains.yaml) file includes a `scan-image` task that:

1. Downloads Trivy
2. Scans the image for **vulnerabilities and secrets** (including image config secrets)
3. Generates a full JSON scan report
4. Downloads `oras` and attaches the scan results to the image as an **unsigned OCI artifact**
5. Emits Tekton Chains **type-hinted results** (`SCAN_RESULTS-ARTIFACT_URI` and `SCAN_RESULTS-ARTIFACT_DIGEST`) so that Chains records the scan results reference as a subject in the SLSA provenance

**Why oras attach instead of cosign attest?** The signing key belongs in the `tekton-chains` namespace — not in `ci` where the pipeline runs. Tekton Chains handles all signing centrally. The pipeline just needs to attach the raw scan results blob to the image (no signature needed at this point), and Chains will include the artifact's digest in the signed provenance it generates after the pipeline completes.

The scan results are discoverable via the OCI referrers API with artifact type `application/vnd.aquasecurity.trivy.report+json`.

```yaml
# In the pipeline, after push-container-image:
- name: scan-image
  runAfter: ["push-container-image"]
  taskRef:
    name: scan-image
  params:
    - name: IMAGE_URL
      value: $(tasks.push-container-image.results.IMAGE_URL)
    - name: IMAGE_DIGEST
      value: $(tasks.push-container-image.results.IMAGE_DIGEST)
```

The scan and SBOM generation tasks run **in parallel** after the image push, since they are independent of each other.

### 2.5 Custom Trivy Rego Policy: Detecting the .git Leak Pattern

Since no scanner reliably detects secrets hidden in git history inside image layers, the most effective detection approach operates on the **Dockerfile source** rather than the built image. Trivy's misconfiguration scanner supports custom Rego policies that can flag the exact anti-pattern used in Challenge 2.

The custom policy [`trivy-policies/copy_git_leak.rego`](trivy-policies/copy_git_leak.rego) flags two things:

1. **`COPY . .`** — copies the entire build context (including `.git`) into an image layer
2. **`RUN rm -rf .git`** — evidence the developer knows `.git` is dangerous but used layer deletion, which only creates a whiteout marker and does not remove the data from the earlier COPY layer

**Running the policy locally:**

```bash
# Scan a Dockerfile with the custom policy
trivy config \
  --config-check challenges/challenge2/trivy-policies/ \
  --namespaces user \
  challenges/victim-repo-sample/Dockerfile
```

**Expected output against the vulnerable Dockerfile:**

```
Dockerfile (dockerfile)
=======================
Tests: 30 (SUCCESSES: 26, FAILURES: 4)
Failures: 4 (UNKNOWN: 0, LOW: 1, MEDIUM: 0, HIGH: 1, CRITICAL: 2)

 (CRITICAL): COPY copies entire build context (including .git) into image layer.
             Secrets in git history will persist in this layer even if deleted later.
             Use a .dockerignore allowlist or multi-stage build.
────────────────────────────────────────
 Dockerfile:24
   24 [ COPY . .

 (CRITICAL): RUN deletes .git but the data remains in the earlier COPY layer.
             Docker layers are immutable — 'rm -rf .git' only creates a whiteout
             marker in a new layer. Use .dockerignore to prevent .git from entering
             the build context.
────────────────────────────────────────
 Dockerfile:32-34
  32 ┌ RUN rm -rf .git && \
  33 │     rm -rf .env* && \
  34 └     echo "Cleaned up sensitive files"
```

Both findings are rated **CRITICAL** because the `.git` directory can contain full repository history including accidentally committed secrets, credentials, and tokens.

**How the Rego policy works:**

The policy uses Trivy's Dockerfile input schema (`input.Stages[].Commands[]`), where each command has `.Cmd` (instruction name) and `.Value` (arguments). It checks:
- Any `copy` command where a source argument is `"."` (copies entire context)
- Any `run` command whose value contains both `rm ` and `.git`

**Using with TruffleHog for defense in depth:**

> The `./defense-demo.sh` (Phase 1, steps 3–4) runs this exact Rego policy against the vulnerable Dockerfile, then re-scans the fixed image in Phase 4 to confirm the anti-pattern is resolved.

TruffleHog can scan images layer-by-layer and will catch credentials stored directly in files (e.g., `.env` files, API keys in config files). While it cannot reconstruct git history, it complements the Rego policy by catching a different class of leaks:

```bash
# TruffleHog: scan image layers for credentials in files
SSL_CERT_FILE=./certs/registry.crt \
  trufflehog docker --image=registry.sc.local:30443/recipe-api:v1.0

# Trivy Rego: catch the Dockerfile anti-pattern at source
trivy config \
  --config-check challenges/challenge2/trivy-policies/ \
  --namespaces user \
  Dockerfile
```

### 2.6 Running Hadolint locally

hadolint is not installed on the host. Run it via container:

```bash
# On the patched Dockerfile
podman run --rm -i docker.io/hadolint/hadolint < challenges/challenge2/tekton-patched/Dockerfile

# On the vulnerable Dockerfile
podman run --rm -i docker.io/hadolint/hadolint < challenges/victim-repo-sample/Dockerfile

# JSON output for scripting
podman run --rm -i docker.io/hadolint/hadolint hadolint --format json - < <Dockerfile>
```

Image used: `docker.io/hadolint/hadolint` (latest) or pinned `docker.io/hadolint/hadolint:v2.12.0-alpine` (~5MB).

#### Findings on project Dockerfiles (verified 2026-05-16)

**Both vulnerable and patched Dockerfiles produce the same single finding:**

- **DL3018** (warning): "Pin versions in apk add. Instead of `apk add <package>` use `apk add <package>=<version>`"
  - Triggered by `RUN apk --no-cache add ca-certificates`
  - Alpine 3.20 version: `ca-certificates=20260413-r0`

**What hadolint does NOT detect:**

- The `COPY . . + rm -rf .git` supply chain anti-pattern (the core Challenge 2 vulnerability)
- hadolint checks Dockerfile syntax and best practices, not supply chain security patterns
- The custom Trivy Rego policy (`trivy-policies/copy_git_leak.rego`) is needed to catch this — it flags both `COPY . .` (copies .git into layer) and `RUN rm -rf .git` (ineffective deletion) as CRITICAL

**Why:** hadolint was evaluated for the defense demo but dropped — it adds complexity without catching anything the Rego policy doesn't already cover better. The DL3018 fix (version pinning) is a minor style improvement, not security-relevant for the demo narrative.

---

## Phase 3: Attestation and Provenance

> The `./keyless-signing-demo.sh` walks through this phase interactively: local Sigstore stack verification (Fulcio, Rekor, TUF), OIDC identity via projected ServiceAccount token, keyless pipeline execution, and verification with `cosign verify` / `cosign verify-attestation`.

After build and scan, the image should have multiple signed attestations attached to it. Here is what the full supply chain picture looks like:

### 3.1 What Gets Attached to the Image

| Artifact | Created By | Type / Format | Purpose |
|----------|-----------|---------------|---------|
| Image signature | Tekton Chains (automatic) | cosign signature | Proves image was built by trusted pipeline |
| SLSA Provenance | Tekton Chains (automatic) | `https://slsa.dev/provenance/v0.2` | Documents build inputs, steps, materials |
| SBOM | Pipeline task (`generate-and-attest-sbom`) | `https://spdx.dev/Document` (signed attestation) | Lists all packages in the image |
| Vuln + Secret scan | Pipeline task (`scan-image`) | `application/vnd.aquasecurity.trivy.report+json` (OCI referrer) | Records vulnerability and secret findings |

The SLSA provenance generated by Chains includes the scan results artifact digest as a subject (via the `SCAN_RESULTS-ARTIFACT_URI` / `SCAN_RESULTS-ARTIFACT_DIGEST` type-hinted results). This creates an unbroken trust chain: Chains signs the provenance → the provenance references the scan results blob → the blob is attached to the image via OCI referrers.

### 3.2 How Tekton Chains Generates Provenance

Tekton Chains watches for completed TaskRuns/PipelineRuns that emit type-hinted results:

| Result Name | Purpose |
|-------------|---------|
| `IMAGE_URL` | Image reference — tells Chains which image to sign |
| `IMAGE_DIGEST` | Image digest — used for signature binding |
| `CHAINS-GIT_URL` | Source repository — recorded as a provenance material |
| `CHAINS-GIT_COMMIT` | Source commit — recorded as a provenance material |

After the pipeline completes, Chains automatically:
1. Signs the image (stored as `.sig` in the registry)
2. Generates an in-toto SLSA Provenance attestation
3. Signs the attestation
4. Stores it as `.att` in the registry

**Important**: Chains generates PipelineRun attestations only **after the entire pipeline completes**. This means you cannot run Conforma validation inside the same pipeline — see Phase 4 for the correct approach.

### 3.3 How Scan Results and SBOMs Reach the Image

Unlike SLSA provenance (generated by Chains automatically), scan results and SBOMs must be explicitly attached by pipeline tasks.

**Scan results** are attached as an unsigned OCI artifact using `oras attach`. No signing key is needed in the pipeline namespace — the signing key stays in `tekton-chains`:

```bash
# Attach scan results as an OCI referrer (no signature)
oras attach "$IMAGE_URL@$IMAGE_DIGEST" \
  --artifact-type application/vnd.aquasecurity.trivy.report+json \
  --ca-file /certs/ca.crt \
  --registry-config /docker-config/config.json \
  trivy-scan-results.json:application/json
```

The scan results are then discoverable via the OCI referrers API or `oras discover`:

```bash
oras discover "$IMAGE_URL@$IMAGE_DIGEST" \
  --artifact-type application/vnd.aquasecurity.trivy.report+json
```

**SBOMs** are attached as signed in-toto attestations using `cosign attest` (the SBOM task uses the cosign signing key from the pipeline's cosign-signing-secret).

Tekton Chains ties everything together: it generates the SLSA provenance after the pipeline completes, and that provenance includes the scan results digest as a subject (via the type-hinted `SCAN_RESULTS-ARTIFACT_URI` / `SCAN_RESULTS-ARTIFACT_DIGEST` results).

### 3.4 Verifying Artifacts from the CLI

After the pipeline completes:

```bash
# Verify image signature (created by Tekton Chains)
cosign verify --key cosign.pub \
  --insecure-ignore-tlog=true \
  registry.sc.local:30443/recipe-api:v1.0

# Verify SLSA provenance (created by Chains — includes scan results digest)
cosign verify-attestation --key cosign.pub \
  --type slsaprovenance \
  --insecure-ignore-tlog=true \
  registry.sc.local:30443/recipe-api:v1.0

# Verify SBOM attestation (signed by pipeline task)
cosign verify-attestation --key cosign.pub \
  --type spdxjson \
  --insecure-ignore-tlog=true \
  registry.sc.local:30443/recipe-api:v1.0

# Discover scan results attached via oras (unsigned OCI referrer)
oras discover registry.sc.local:30443/recipe-api:v1.0 \
  --artifact-type application/vnd.aquasecurity.trivy.report+json

# Download and inspect the scan results blob
oras pull registry.sc.local:30443/recipe-api@<referrer-digest> \
  --output /tmp/scan-results/
cat /tmp/scan-results/trivy-scan-results.json | jq '.Results[] | {Target, Vulnerabilities: (.Vulnerabilities // [] | length), Secrets: (.Secrets // [] | length)}'

# Inspect the SLSA provenance to confirm scan results are recorded as a subject
cosign verify-attestation --key cosign.pub \
  --type slsaprovenance \
  --insecure-ignore-tlog=true \
  registry.sc.local:30443/recipe-api:v1.0 | jq -r .payload | base64 -d | jq '.predicate.buildConfig'
```

---

## Phase 4: Policy Enforcement with Conforma

> **No demo script yet**: Conforma validation is documented here but not yet covered by an interactive demo. See `./defense-demo.sh` for the build/scan/verify workflow that precedes Conforma.

Conforma (formerly Enterprise Contract, `ec` CLI) validates images against Rego-based policies. It checks that:
- The image is signed
- SLSA provenance exists and meets requirements
- SBOM is present
- Vulnerability scan results exist and pass severity thresholds

### 4.1 How Conforma Works

Conforma fetches the image's signature and attestations from the registry, then evaluates Rego policy rules against them:

```
[OCI Registry]
  ├── Image (recipe-api:v1.0)
  ├── .sig  (cosign signature)
  └── .att  (attestations)
       ├── SLSA Provenance (Chains)
       ├── SBOM (pipeline task)
       └── Vuln scan (pipeline task)
           ↓
[ec validate image]
  ├── Verify signature → cosign.pub
  ├── Parse attestations
  ├── Evaluate Rego policies
  └── Pass / Fail
```

### 4.2 Running Conforma After the Pipeline

Because Chains generates PipelineRun provenance only after pipeline completion, Conforma must run **outside** the pipeline:

```bash
SSL_CERT_FILE=./certs/registry.crt \
ec validate image \
  --image registry.sc.local:30443/recipe-api:v1.0 \
  --public-key cosign.pub \
  --policy '{"sources":[{"name":"sc-policy","policy":["github.com/conforma/policy//policy/lib","github.com/conforma/policy//policy/release"],"config":{"include":["@minimal"],"exclude":[]}}]}' \
  --ignore-rekor \
  --extra-rule-data 'allowed_registry_prefixes=["registry.registry.svc.cluster.local:5000","registry.sc.local:30443"]' \
  --output text
```

### 4.3 What Conforma Policy Rules Check

Conforma ships with 48 policy rule packages. The ones relevant to Challenge 2:

| Package | Rule | What It Checks |
|---------|------|----------------|
| `attestation_type` | `pipelinerun_attestation_found` | SLSA provenance exists |
| `sbom` | `found` | At least one SBOM attestation is present |
| `sbom_spdx` | `valid`, `contains_packages`, `matches_image` | SBOM is valid SPDX and matches the image |
| `cve` | `cve_results_found` | Vulnerability scan results exist |
| `cve` | `cve_blockers` | No patched CVEs at blocking severity |
| `cve` | `unpatched_cve_blockers` | No unpatched CVEs at blocking severity |
| `signature` | `valid` | Image has a valid cosign signature |

**Conforma does NOT have a built-in policy for secret scan results.** The `cve.*` rules check vulnerability scan data (format: cosign-vuln predicate), which includes Trivy's secret findings if `--scanners vuln,secret` was used. However, there is no dedicated rule that specifically fails on secret detections. For strict secret-scan enforcement, you would need a custom Rego rule.

### 4.4 What Happens When Conforma Fails

Conforma supports two enforcement modes:

| Flag | Behavior |
|------|----------|
| `--strict true` | Exit code non-zero on any violation — can gate CI/CD |
| `--strict false` | Always exits 0 — violations reported in output only |

**Conforma is NOT a Kubernetes admission controller.** It is a CLI/pipeline tool. It does not intercept pod creation or deployment requests. A Conforma failure stops the pipeline or CI script, but cannot prevent someone from deploying the image directly.

### 4.5 The Pipeline Already Pushed the Image

This is the critical gap: by the time scanning and policy validation run, the image is already in the registry. Anyone with registry access can pull it.

**Defense options for preventing deployment of non-compliant images:**

1. **Kyverno `verifyImages` policies** (admission controller — blocks pods at deploy time):
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature-and-attestations
      match:
        any:
        - resources:
            kinds: [Pod]
      verifyImages:
        - imageReferences: ["registry.registry.svc.cluster.local:5000/*"]
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...
                      -----END PUBLIC KEY-----
          attestations:
            - predicateType: "https://cosign.sigstore.dev/attestation/vuln/v1"
              conditions:
                - all:
                  - key: "{{ scanner.result.Results[].Secrets || `[]` }}"
                    operator: Equals
                    value: []
```

2. **Sigstore Policy Controller** (admission webhook — verifies signatures and attestations):
   Namespaces opt in with label `policy.sigstore.dev/include: "true"`.

3. **Registry separation**: Push to a staging registry; promote to production only after Conforma passes.

4. **Conforma in a follow-up pipeline/integration test**: A separate pipeline triggers after the build pipeline completes, validates the image, and promotes or rejects it.

---

## Phase 5: The Complete Secured Pipeline

### 5.1 Pipeline Architecture

```
git-clone
  └─ build-go-app
       └─ run-quality-checks
            └─ build-container-image
                 └─ push-container-image-with-chains   (emits IMAGE_URL + IMAGE_DIGEST)
                      ├─ scan-image                     (Trivy vuln+secret scan → oras attach)
                      └─ generate-and-attest-sbom       (Trivy SBOM → cosign attest --type spdxjson)

[Pipeline completes → Tekton Chains generates SLSA Provenance
                       (includes scan results digest via type hints)]

[Post-pipeline: ec validate image (Conforma)]

[Deploy time: Kyverno verifies signature + attestations]
```

The scan and SBOM tasks run in parallel after the push, minimizing pipeline duration.

### 5.2 Deploy the Secured Pipeline

```bash
# Deploy the Chains-aware pipeline with scanning
make setup-challenge2-tekton

# Trigger the secured pipeline
make trigger-challenge2-build-with-chains

# Wait for pipeline completion, then validate with Conforma
make verify-conforma
```

### 5.3 Verify the Defenses

> The `./defense-demo.sh` (Phases 3–4) demonstrates the webhook-triggered pipeline and verification. After pushing the Dockerfile fix to main, the Gitea webhook triggers the EventListener → PipelineRun automatically. Phase 4 then verifies the new v2.0 image has no secrets and re-runs the Rego policy to confirm the anti-pattern is gone.

After the pipeline completes:

```bash
# 1. Check all attestations are present
cosign tree registry.sc.local:30443/recipe-api:v1.0

# 2. Verify vulnerability scan found no critical issues
cosign verify-attestation --key cosign.pub \
  --type vuln \
  --insecure-ignore-tlog=true \
  registry.sc.local:30443/recipe-api:v1.0 | jq -r .payload | base64 -d | jq '.predicate.scanner'

# 3. Verify SBOM lists expected packages
cosign verify-attestation --key cosign.pub \
  --type spdxjson \
  --insecure-ignore-tlog=true \
  registry.sc.local:30443/recipe-api:v1.0 | jq -r .payload | base64 -d | jq '.predicate.packages | length'

# 4. Run Conforma policy check
SSL_CERT_FILE=./certs/registry.crt \
ec validate image \
  --image registry.sc.local:30443/recipe-api:v1.0 \
  --public-key cosign.pub \
  --policy '{"sources":[{"name":"sc","policy":["github.com/conforma/policy//policy/lib","github.com/conforma/policy//policy/release"],"config":{"include":["@minimal"],"exclude":[]}}]}' \
  --ignore-rekor \
  --output text
```

---

## Summary: Defense-in-Depth Layers

| Layer | Tool | What It Does | When It Acts |
|-------|------|-------------|-------------|
| **Prevention** | `.dockerignore` | Excludes secrets from build context | Build time |
| **Prevention** | Multi-stage Dockerfile | Isolates build env from runtime image | Build time |
| **Prevention** | `--mount=type=secret` | Injects secrets without layer persistence | Build time |
| **Remediation** | `git-filter-repo` | Rewrites git history to permanently remove leaked secrets | Post-incident |
| **Detection** | Trivy (`--scanners secret`) | Scans image for secrets in final filesystem | Post-build |
| **Detection** | Trivy (`--scanners vuln`) | Scans for known CVEs | Post-build |
| **Transparency** | Trivy SBOM | Lists all packages for auditing | Post-build |
| **Trust** | Tekton Chains | Signs image, generates SLSA provenance | Post-pipeline |
| **Trust** | oras attach | Attaches scan results as OCI referrer (unsigned) | Post-build |
| **Trust** | cosign attest | Attaches SBOM as signed attestation | Post-build |
| **Policy** | Conforma (ec CLI) | Verifies attestations meet policy requirements | Post-pipeline |
| **Enforcement** | Kyverno / Policy Controller | Blocks deployment of unsigned/non-compliant images | Deploy time |

**Key Takeaway**: No single tool catches everything. `.dockerignore` prevents the leak. Trivy detects it if prevention fails. Attestations create a verifiable record. Conforma checks the record. Admission controllers enforce the policy at deploy time. You need all layers.

---

## Tool Documentation

- **Trivy**: https://trivy.dev/docs/latest/
- **oras**: https://oras.land/docs/
- **cosign**: https://docs.sigstore.dev/cosign/
- **Tekton Chains**: https://tekton.dev/docs/chains/
- **Conforma (EC)**: https://conforma.dev/docs/
- **Kyverno**: https://kyverno.io/docs/
- **Hadolint**: https://github.com/hadolint/hadolint
- **dive**: https://github.com/wagoodman/dive
- **git-filter-repo**: https://github.com/newren/git-filter-repo

For the complete attack analysis, see [ATTACK-ANALYSIS.md](ATTACK-ANALYSIS.md).
