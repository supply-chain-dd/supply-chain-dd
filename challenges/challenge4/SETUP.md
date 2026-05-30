# Challenge 4: GitOps Pipeline Compromise - Setup Guide

This guide walks you through setting up the production environment and GitOps pipeline for the final deep dive challenge.

## Prerequisites

Before proceeding, ensure you have completed:

1. **Challenge 1**: To understand the deep dive environment
2. **Challenge 2**: The `.env.production` file with ArgoCD credentials must be in the git history
3. **Main environment**: KinD cluster (`ci-cluster`), Gitea, Registry, and Tekton installed

```bash
make setup                    # Main deep dive environment
make setup-registry           # Docker registry
make configure-registry-tls   # Registry TLS trust
```

## Overview

Challenge 4 demonstrates a **GitOps pipeline compromise** attack where an attacker:
1. Extracts ArgoCD credentials from Challenge 2 (leaked in `.env.production`)
2. Accesses the production GitOps deployment pipeline  
3. Injects malicious workloads into production Kubernetes manifests
4. Deploys backdoors, cryptominers, or data exfiltration pods

## Architecture

```
┌─────────────────────┐         ┌──────────────────────────┐
│  CI Cluster        │         │  Production Cluster      │
│  (ci-cluster)      │         │  (production-cluster)        │
│                     │         │                          │
│  ┌──────────────┐   │         │  ┌────────────────────┐  │
│  │  Gitea       │   │         │  │  Gitea (prod)      │  │
│  │  recipe-api  │   │         │  │  prod-manifests    │  │
│  │  (.env leak) │   │         │  └──────┬─────────────┘  │
│  └──────────────┘   │         │         │ Git Sync       │
│                     │         │  ┌──────▼─────────────┐  │
│                     │         │  │  ArgoCD            │  │
│                     │         │  │                    │  │
│                     │         │  └────────┬───────────┘  │
│                     │         │           │              │
│                     │         │  ┌────────▼───────────┐  │
│                     │         │  │  Recipe API        │  │
│                     │         │  │  (production)      │  │
│                     │         │  └────────────────────┘  │
└─────────────────────┘         └──────────────────────────┘
                                          ▲
                                          │ Attacker modifies
                                          │ manifests via Git
                                          │
                                     ┌────┴──────┐
                                     │  Attacker │
                                     │ (with     │
                                     │  stolen   │
                                     │  creds)   │
                                     └───────────┘
```

## Automated Setup (Recommended)

The fastest way to set up Challenge 4 is using the automated setup:

```bash
# Complete automated setup (creates cluster, Gitea, ArgoCD, seeds repository, and deploys application)
make setup-challenge4

# Verify setup
make verify-challenge4
```

This automates all the steps below including:
- Creating production KinD cluster
- Installing production Gitea
- Loading recipe-api image into production cluster (from CI cluster registry)
- Installing ArgoCD
- Seeding production-manifests repository
- Deploying ArgoCD application

**Note**: Before running this, ensure you've built the recipe-api image in Challenge 2:
```bash
cd challenges/challenge2
make build-recipe-api
make push-recipe-api
```

**Skip to "Verify Complete Setup" if using automated setup.**

---

## Manual Setup (Step by Step)

If you prefer to understand each component, follow these steps:

### Step 1: Create Production KinD Cluster

Create a second KinD cluster to simulate the production environment:

```bash
make setup-production-cluster
```

This creates:
- Cluster name: `production-cluster`
- Context: `kind-production-cluster`
- NodePorts: 30080 (ArgoCD HTTP), 30443 (ArgoCD HTTPS), 30004 (Gitea HTTP), 30005 (Gitea SSH), 30081 (recipe-api)

**Verify**:
```bash
kind get clusters
# Should show: ci-cluster, production-cluster

kubectl config get-contexts
# Should show both contexts
```

### Step 2: Install Gitea on Production Cluster

Install a separate Gitea instance on the production cluster for GitOps manifests:

```bash
# Switch to production cluster
kubectl config use-context kind-production-cluster

# Install Gitea
make setup-production-gitea
```

This installs:
- **Gitea** in the `gitea` namespace
- Web UI accessible at http://gitea-prod.sc.local:31080
- SSH access at ssh://git@gitea-prod.sc.local:30005
- Same credentials: `sc-admin` / `SecurePass123!`

**Verify**:
```bash
kubectl get pods -n gitea
# Gitea pod should be Running

curl http://gitea-prod.sc.local:31080
# Should return Gitea web page
```

### Step 3: Load recipe-api Image into Production Cluster

Since the production cluster can't access the CI cluster's registry, we need to load the image directly:

```bash
# Load the recipe-api image into production cluster (works with Docker or Podman)
make load-image-to-production
```

This loads `registry.sc.local:30443/recipe-api:v1.0` from your local container runtime into the production cluster's containerd, making it available for deployment.

**Prerequisites**: Ensure you've built the recipe-api image first:
```bash
cd challenges/challenge2
make build-recipe-api
make push-recipe-api
cd ../..
```

**Verify**:
```bash
# The image should now be available in the production cluster
kubectl --context kind-production-cluster run test --image=registry.sc.local:30443/recipe-api:v1.0 --dry-run=client
# Should succeed without errors
```

### Step 4: Install ArgoCD

Install ArgoCD on the production cluster:

```bash
# Install ArgoCD (should still be on production cluster context)
make setup-argocd
```

This installs:
- **ArgoCD** in the `argocd` namespace
- **Vulnerable RBAC** (cluster-admin permissions - intentional!)
- **Production namespace** for application deployment

**Verify**:
```bash
kubectl get pods -n argocd
# All pods should be Running
```

**Access ArgoCD Web UI**:
```
URL: https://argocd.sc.local:31443
Username: admin
Password: admin123
```

**ArgoCD Token Configuration**:
The setup script automatically configures ArgoCD to accept the token from `.env.production`:
```
Token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE
```

This token is intentionally configured with a weak JWT signing secret for the deep dive purposes.

### Step 5: Seed production-manifests Repository

Create and populate the `production-manifests` repository in production Gitea:

```bash
# Seed the repository (automated)
make seed-production-repo
```

This automatically:
1. Creates the `production-manifests` repository in production Gitea via API
2. Copies manifests from `challenges/challenge4/production-manifests-sample/`
3. Initializes git repository and pushes to production Gitea

**Verify**:
```bash
# Check repository exists
curl -u sc-admin:SecurePass123! http://gitea-prod.sc.local:31080/api/v1/repos/sc-admin/production-manifests

# Or visit in browser
# http://gitea-prod.sc.local:31080/sc-admin/production-manifests
```

### Step 6: Configure ArgoCD Application

Create an ArgoCD Application that syncs the production-manifests repository:

```bash
# Apply ArgoCD application (should still be on production cluster context)
kubectl apply -f challenges/challenge4/argocd/recipe-api-application.yaml
```

**Verify Application Sync**:
```bash
# Check application status
kubectl get applications -n argocd

# Check deployed resources in production namespace
kubectl get all -n production

# Expected: recipe-api deployment, service, and pods should be created
```

**In ArgoCD Web UI**:
1. Navigate to https://argocd.sc.local:31443
2. Login as admin
3. You should see the `recipe-api-production` application
4. Status should be "Synced" and "Healthy"

## Verify Complete Setup

Run the verification:

```bash
make verify-challenge4
```

**Expected Output**:
```
✓ Production cluster exists
✓ Gitea running on production cluster
✓ ArgoCD running
✓ ArgoCD applications deployed
✓ Production namespace exists
✓ Recipe-API deployment in production
```

## Environment State After Setup

**CI Cluster (ci-cluster)**:
- ✅ Gitea with `recipe-api` (contains leaked .env.production in git history)
- ✅ Docker Registry with `recipe-api:v1.0` image
- ✅ Tekton CI/CD pipelines

**Production Cluster (production-cluster)**:
- ✅ Gitea with `production-manifests` repository (GitOps manifests)
  - Accessible at http://gitea-prod.sc.local:31080
  - Internal URL: http://gitea-http.gitea.svc.cluster.local:3000
- ✅ ArgoCD with **vulnerable RBAC** (cluster-admin access)
  - Web UI: https://argocd.sc.local:31443
- ✅ Production namespace with recipe-api deployed
- ✅ ArgoCD syncing from production Gitea
- ⚠️ **No admission policies** (Kyverno not installed - vulnerable!)
- ⚠️ **No network policies** (unrestricted egress - vulnerable!)

## Attack Surface

The vulnerable configuration enables the attack:

1. **Leaked ArgoCD Credentials**: In `.env.production` (Challenge 2)
   ```
   ARGOCD_AUTH_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE
   ARGOCD_SERVER=argocd-server.argocd.svc.cluster.local
   ARGOCD_APP_NAME=recipe-api-production
   ```
   
   This token is valid and accepted by ArgoCD because:
   - The JWT signing secret is intentionally weak: `Deploy_Token_SuperSecret!`
   - The token ID `sc-deployer` is registered in ArgoCD configuration
   - Configured automatically during `make setup-argocd`

2. **Excessive RBAC Permissions**:
   - ArgoCD controller has `cluster-admin` (full cluster access)
   - Can deploy any workload, modify RBAC, access secrets

3. **No Admission Policies**:
   - No Kyverno/OPA blocking malicious pods
   - Privileged containers allowed
   - No resource limits enforced

4. **No Network Policies**:
   - Pods can egress to any external IP
   - Reverse shells and data exfiltration not blocked

5. **No Image Verification**:
   - Images not signed or verified
   - Attacker can push malicious images to registry

## Next Steps

**For Participants**:
1. Complete Challenge 2 to extract `.env.production`
2. Find ArgoCD credentials in the file
3. Follow [ATTACK-GUIDE.md](./ATTACK-GUIDE.md) to execute the attack

**For Organizers**:
1. Test the attack: See [ATTACK-GUIDE.md](./ATTACK-GUIDE.md)
2. Review detection: See [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)
3. Apply security: See [SECURITY-GUIDE.md](./SECURITY-GUIDE.md)

## Troubleshooting

### ArgoCD can't reach Gitea

**Problem**: ArgoCD shows "connection refused" for Git repository.

**Solution**: Gitea should be running on the production cluster itself. Verify:
```bash
kubectl --context kind-production-cluster get pods -n gitea
# Should show Gitea pod Running

kubectl --context kind-production-cluster get svc -n gitea
# Should show gitea-http service
```

If Gitea is not installed on the production cluster:
```bash
kubectl config use-context kind-production-cluster
make setup-production-gitea
make seed-production-repo
```

### Application not syncing

**Problem**: ArgoCD application shows "OutOfSync".

**Solution**:
```bash
# Force sync
argocd app sync recipe-api-production --server argocd.sc.local:31443 --insecure

# Or via kubectl
kubectl patch application recipe-api-production -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### Registry image pull failures (ErrImagePull)

**Problem**: Pods show `ErrImagePull` or `ImagePullBackOff` for `registry.sc.local:30443/recipe-api:v1.0`.

**Cause**: The production cluster can't access the CI cluster's registry at `registry.sc.local:30443`.

**Solution**: Load the image into the production cluster:
```bash
# Ensure recipe-api image exists locally
cd challenges/challenge2
make build-recipe-api
make push-recipe-api

# Load into production cluster
cd ../..
make load-image-to-production

# Restart the deployment to pull the newly loaded image
kubectl --context kind-production-cluster rollout restart deployment/recipe-api -n production
```

This loads the image from your local container runtime (Docker/Podman) directly into the production cluster's containerd.

## Cleanup

To remove the Challenge 4 environment:

```bash
# Delete production cluster
make clean-challenge4

# Or manually
kind delete cluster --name production-cluster
```

This leaves the main CI cluster intact.

## Security Hardening (Optional)

To demonstrate the security controls that would prevent this attack:

```bash
# Apply security policies to production cluster
make apply-challenge4-security

# Test that attacks are now blocked
make test-challenge4-attack
```

See [SECURITY-GUIDE.md](./SECURITY-GUIDE.md) for details.

## Files Overview

```
challenges/challenge4/
├── SETUP.md                          # This file
├── ATTACK-GUIDE.md            # Attack walkthrough
├── ATTACK-ANALYSIS.md                # Technical analysis
├── SECURITY-GUIDE.md                 # Detection & prevention
├── argocd/                           # ArgoCD configuration
│   ├── argocd-values.yaml            # Helm values (vulnerable!)
│   ├── recipe-api-application.yaml   # ArgoCD Application
│   ├── vulnerable-rbac.yaml          # Excessive permissions
│   └── namespace.yaml                # Namespace definitions
├── production-manifests-sample/      # GitOps repository
│   └── recipe-api/                   # Application manifests
├── attack-payloads/                  # Malicious workloads
│   ├── backdoored-deployment.yaml    # Injected backdoor
│   ├── malicious-pod.yaml            # Cryptocurrency miner
│   └── data-exfil-cronjob.yaml       # Secret exfiltration
├── security/                         # Prevention & detection
│   ├── kyverno-policies/             # Admission control
│   ├── network-policies/             # Network segmentation
│   ├── rbac/                         # Least-privilege RBAC
│   └── falco-rules/                  # Runtime detection
└── scripts/                          # Helper scripts
```

## Support

**Questions?** Review the documentation:
- **Setup issues**: This file
- **Attack execution**: [ATTACK-GUIDE.md](./ATTACK-GUIDE.md)
- **How it works**: [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)
- **How to prevent**: [SECURITY-GUIDE.md](./SECURITY-GUIDE.md)
