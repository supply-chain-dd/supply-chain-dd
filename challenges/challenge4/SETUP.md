# Challenge 4: GitOps Pipeline Compromise - Setup Guide

This guide walks you through setting up the production environment and GitOps pipeline for the final CTF challenge.

## Prerequisites

Before proceeding, ensure you have completed:

1. **Challenge 1**: To understand the CTF environment
2. **Challenge 2**: The `.env.production` file with ArgoCD credentials must be in the git history
3. **Main environment**: KinD cluster (`ctf-cluster`), Gitea, Registry, and Tekton installed

```bash
make setup                    # Main CTF environment
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
┌─────────────────────┐         ┌──────────────────────┐
│  CTF Cluster        │         │  Production Cluster  │
│  (ctf-cluster)      │         │  (ctf-production)    │
│                     │         │                      │
│  ┌──────────────┐   │         │  ┌────────────────┐  │
│  │  Gitea       │◄──┼─────────┼──┤  ArgoCD        │  │
│  │  victim-repo │   │   Git   │  │                │  │
│  └──────────────┘   │   Sync  │  └────────┬───────┘  │
│                     │         │            │          │
│  ┌──────────────┐   │         │  ┌─────────▼───────┐  │
│  │  Gitea       │◄──┼─────────┼──┤  Recipe API     │  │
│  │  prod-manifests│ │         │  │  (production)   │  │
│  └──────────────┘   │         │  └─────────────────┘  │
└─────────────────────┘         └──────────────────────┘
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

## Step 1: Create Production KinD Cluster

Create a second KinD cluster to simulate the production environment:

```bash
make setup-production-cluster
```

This creates:
- Cluster name: `ctf-production-cluster`
- Context: `kind-ctf-production-cluster`
- NodePorts: 30080 (HTTP), 30443 (HTTPS) for ArgoCD access

**Verify**:
```bash
kind get clusters
# Should show: ctf-cluster, ctf-production-cluster

kubectl config get-contexts
# Should show both contexts
```

## Step 2: Install ArgoCD

Switch to the production cluster and install ArgoCD:

```bash
# Switch context
kubectl config use-context kind-ctf-production-cluster

# Install ArgoCD
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
URL: https://localhost:30443
Username: admin
Password: admin123
```

**ArgoCD Token Configuration**:
The setup script automatically configures ArgoCD to accept the token from `.env.production`:
```
Token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE
```

This token is intentionally configured with a weak JWT signing secret for CTF purposes.

## Step 3: Create production-manifests Repository in Gitea

Create a Git repository in Gitea that ArgoCD will sync from.

### 3.1 Create Repository in Gitea Web UI

1. Navigate to http://localhost:30002
2. Login as `ctf-admin` / `CTFSecurePass123!`
3. Click "+" → "New Repository"
4. Fill in:
   - Repository Name: `production-manifests`
   - Visibility: **Public** (for easier access)
   - Initialize: **DO NOT** check any initialization options
5. Click "Create Repository"

### 3.2 Push Manifests to Gitea

```bash
cd challenges/challenge4/production-manifests-sample

# Initialize git repository
git init
git add .
git commit -m "Initial production manifests for recipe-api"

# Add Gitea remote (switch to CTF cluster context first!)
kubectl config use-context kind-ctf-cluster
GITEA_URL="http://localhost:30002/ctf-admin/production-manifests.git"
git remote add origin $GITEA_URL

# Push to Gitea
git push -u origin main
```

**Verify**:
```bash
# Clone to verify
git clone http://localhost:30002/ctf-admin/production-manifests.git /tmp/verify-prod-manifests
ls /tmp/verify-prod-manifests/recipe-api/
# Should show: deployment.yaml, service.yaml, serviceaccount.yaml, kustomization.yaml
```

## Step 4: Configure ArgoCD Application

Create an ArgoCD Application that syncs the production-manifests repository.

```bash
# Switch back to production cluster
kubectl config use-context kind-ctf-production-cluster

# Apply ArgoCD application
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
1. Navigate to https://localhost:30443
2. Login as admin
3. You should see the `recipe-api-production` application
4. Status should be "Synced" and "Healthy"

## Step 5: Verify Complete Setup

Run the verification:

```bash
make verify-challenge4
```

**Expected Output**:
```
✓ Production cluster exists
✓ ArgoCD pods running
✓ ArgoCD applications deployed
✓ Production namespace exists
✓ Recipe-API running in production
```

## Environment State After Setup

**CTF Cluster (ctf-cluster)**:
- ✅ Gitea with two repositories:
  - `victim-repo` (contains leaked .env.production in git history)
  - `production-manifests` (GitOps manifests for production)
- ✅ Docker Registry with `recipe-api:v1.0` image
- ✅ Tekton CI/CD pipelines

**Production Cluster (ctf-production-cluster)**:
- ✅ ArgoCD with **vulnerable RBAC** (cluster-admin access)
- ✅ Production namespace with recipe-api deployed
- ✅ ArgoCD syncing from Gitea production-manifests repository
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
   - The JWT signing secret is intentionally weak: `CtF_Deploy_Token_SuperSecret!`
   - The token ID `ctf-deployer` is registered in ArgoCD configuration
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

**For CTF Participants**:
1. Complete Challenge 2 to extract `.env.production`
2. Find ArgoCD credentials in the file
3. Follow [CTF-CHALLENGE-GUIDE.md](./CTF-CHALLENGE-GUIDE.md) to execute the attack

**For CTF Organizers**:
1. Test the attack: See [CTF-CHALLENGE-GUIDE.md](./CTF-CHALLENGE-GUIDE.md)
2. Review detection: See [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)
3. Apply security: See [SECURITY-GUIDE.md](./SECURITY-GUIDE.md)

## Troubleshooting

### ArgoCD can't reach Gitea

**Problem**: ArgoCD shows "connection refused" for Git repository.

**Solution**: Ensure both clusters can communicate. Gitea is in the CTF cluster but accessible via NodePort. Update the repository URL in `recipe-api-application.yaml` to use the host's IP or `host.docker.internal`.

### Application not syncing

**Problem**: ArgoCD application shows "OutOfSync".

**Solution**:
```bash
# Force sync
argocd app sync recipe-api-production --server localhost:30443 --insecure

# Or via kubectl
kubectl patch application recipe-api-production -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### Registry image pull failures

**Problem**: Pods can't pull `localhost:30000/recipe-api:v1.0`.

**Solution**: The production cluster needs registry access. Configure containerd or add imagePullSecrets with registry credentials.

## Cleanup

To remove the Challenge 4 environment:

```bash
# Delete production cluster
make clean-challenge4

# Or manually
kind delete cluster --name ctf-production-cluster
```

This leaves the main CTF cluster intact.

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
├── CTF-CHALLENGE-GUIDE.md            # Attack walkthrough
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
- **Attack execution**: [CTF-CHALLENGE-GUIDE.md](./CTF-CHALLENGE-GUIDE.md)
- **How it works**: [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)
- **How to prevent**: [SECURITY-GUIDE.md](./SECURITY-GUIDE.md)
