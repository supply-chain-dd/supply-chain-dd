# Challenge 3 Setup: Malware in Base Image Attack

## Prerequisites

Before starting this challenge, you must complete:
- ✅ **Challenge 1**: To obtain registry credentials (`sc-admin` / `RegistryPass123!`)
- ✅ **Challenge 2**: Legitimate base image `golang:1.25-alpine` seeded to registry during Challenge 2 setup
- ✅ **Environment setup**: KinD cluster, registry, Gitea, and Tekton installed

## Overview

This challenge demonstrates a **base image poisoning attack** where an attacker with registry write access can inject malware into commonly used base images. When legitimate builds pull the poisoned base image, the malware becomes embedded in production containers.

## Attack Prerequisites

From **Challenge 1**, you should have:
- Registry URL: `https://registry.sc.local:30443`
- Registry credentials: `sc-admin` / `RegistryPass123!`
- Registry certificate: `certs/registry.crt`

From **Challenge 2**, the registry should contain:
- Legitimate base image: `registry.sc.local:30443/golang:1.25-alpine`

## Initial State Setup

### 1. Verify Registry Access

```bash
# Login to the registry with stolen credentials from Challenge 1
podman login registry.sc.local:30443 -u sc-admin -p RegistryPass123!

# Verify you can push images
podman pull golang:1.23-alpine
podman tag golang:1.23-alpine registry.sc.local:30443/test-image:latest
podman push registry.sc.local:30443/test-image:latest
```


### 2. Verify Legitimate Base Image Exists

The legitimate base image should already exist from Challenge 2 setup:

```bash
# Verify the base image is in the registry
# From the repo's root
curl --cacert setup/certs/registry.crt -u sc-admin:RegistryPass123! \
  https://registry.sc.local:30443/v2/golang/tags/list

# Expected output: {"name":"golang","tags":["1.25-alpine"]}
```

**If the base image is missing** (setup-challenge2 not run):

```bash
# Manually seed the legitimate base image
make seed-legitimate-base-image

# Or do it manually:
podman pull golang:1.25-alpine
podman tag golang:1.25-alpine registry.sc.local:30443/golang:1.25-alpine
podman login registry.sc.local:30443 --tls-verify=false -u sc-admin -p RegistryPass123!
podman push registry.sc.local:30443/golang:1.25-alpine 
```

### 4. Verify Pipeline Configuration

The Tekton pipeline should build the `recipe-api` using this Dockerfile:

```bash
# Check current pipeline runs
kubectl get pipelineruns -n ci

# Verify the build task pulls from registry.registry.svc.cluster.local:5000
tkn pr logs <latest-run> -n ci | grep -A5 " from registry "
```

## Attack Surface

**What makes this attack possible:**

1. **Registry write access**: Attacker obtained credentials from Challenge 1
2. **No image verification**: Pipeline doesn't verify base image signatures or digests
3. **Tag-based pulling**: Using `golang:1.25-alpine` (mutable tag) instead of digest `@sha256:...`
4. **No SBOM validation**: No Software Bill of Materials checking
5. **No runtime monitoring**: Malware execution isn't detected

## Environment State After Setup

✅ Registry accessible with valid credentials  
✅ Legitimate base image `registry.sc.local:30443/golang:1.25-alpine` exists  
✅ Victim repository Dockerfile references local registry base image  
✅ Pipeline configured to build from local registry  

## Next Steps

Proceed to [ATTACK-GUIDE.md](ATTACK-GUIDE.md) to execute the attack.

## Troubleshooting

### Registry login fails
```bash
# Reconfigure TLS trust
make configure-registry-tls

# Or copy certificate manually
sudo cp certs/registry.crt /etc/containers/certs.d/registry.sc.local:30443/ca.crt
```

### Base image doesn't exist
```bash
# Re-seed the legitimate base image
podman pull golang:1.23-alpine
podman tag golang:1.23-alpine registry.sc.local:30443/golang:1.25-alpine
podman push registry.sc.local:30443/golang:1.25-alpine
```

### Can't verify Dockerfile in Gitea
```bash
# Clone the recipe-api repository locally
git clone http://gitea.sc.local:30080/sc-admin/recipe-api.git
cd recipe-api
cat Dockerfile
```
