# Production Manifests Sample

This folder contains Kubernetes manifests for the production deployment of the recipe-api application.  
This is intended to be created as a **Git repository in Gitea** that ArgoCD will sync from.

## Purpose

In Challenge 4, participants will:
1. Extract ArgoCD credentials from the `.env.production` file (found in Challenge 2)
2. Create this repository in Gitea
3. Configure ArgoCD to sync from this repository
4. Use stolen credentials to modify deployments and inject malicious payloads

## Repository Structure

```
production-manifests/
└── recipe-api/
    ├── deployment.yaml       # Recipe API Deployment
    ├── service.yaml          # Recipe API Service
    ├── serviceaccount.yaml   # ServiceAccount and Secrets
    └── kustomization.yaml    # Kustomize configuration
```

## Setup Instructions (For CTF Organizers)

### Step 1: Create Repository in Gitea

1. Log into Gitea at http://localhost:30002
2. Create a new repository named `production-manifests`
3. Initialize it as a **public** repository (for easier access)

### Step 2: Push Manifests to Gitea

```bash
cd challenges/challenge4/production-manifests-sample

# Initialize git repository
git init
git add .
git commit -m "Initial production manifests"

# Add Gitea remote
git remote add origin http://localhost:30002/ctf-admin/production-manifests.git

# Push to Gitea
git push -u origin main
```

### Step 3: Verify Repository

```bash
# Clone the repository to verify
git clone http://localhost:30002/ctf-admin/production-manifests.git /tmp/verify-manifests
cd /tmp/verify-manifests
ls -la recipe-api/
```

## For CTF Participants

You will need to:
1. Complete Challenge #2 to extract `.env.production` from container image layers
2. Find ArgoCD credentials in the `.env.production` file
3. Clone or create this repository structure
4. Use ArgoCD to deploy and modify these manifests

See `../SETUP.md` for detailed instructions.

## Deployment Details

### Production Namespace

All resources are deployed to the `production` namespace on a separate KinD cluster  
(`ctf-production-cluster`).

### Application Configuration

- **Image**: `localhost:30000/recipe-api:v1.0` (from Challenge 2)
- **Replicas**: 3 (for high availability)
- **Resources**: CPU 100m-500m, Memory 128Mi-256Mi
- **Security**: Non-root user, read-only filesystem, dropped capabilities

### Secrets

Database credentials are stored in the `recipe-api-secrets` Secret (referenced from .env.production).

## Attack Surface

The vulnerable configuration includes:
- **ServiceAccount** with potentially excessive permissions
- **No image signature verification** (allows malicious images)
- **No admission policies** (Kyverno/OPA not enforced)
- **No network policies** (unrestricted egress)

These gaps enable the attack demonstrated in Challenge 4.
