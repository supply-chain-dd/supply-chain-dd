# Challenge 4: GitOps Pipeline Compromise

**Attack Type**: Supply Chain - Continuous Deployment Compromise  
**Difficulty**: Advanced  
**Prerequisites**: Completion of Challenge #2 (Container Image Layer Leak)

## Overview

Challenge 4 demonstrates a **GitOps pipeline attack** where an attacker uses stolen ArgoCD credentials (leaked in Challenge 2) to compromise the production deployment pipeline. The attacker modifies Kubernetes manifests in Git, which ArgoCD automatically syncs to the production cluster, deploying backdoors and malicious workloads.

## Attack Flow

```
Challenge 2          ArgoCD            Git Repository       Production
  (Leak)     →    Credentials   →    Modification    →      Cluster
                                                          
.env.production    JWT Token      Backdoored          Malicious Pods
in container    →  Extracted   →  deployment.yaml  →  Deployed
image layers                      committed to Git
```

## Learning Objectives

After completing this challenge, you will understand:

✅ **GitOps Security Implications**: How CI/CD automation can be weaponized  
✅ **Credential Chaining**: Leveraging previous attack stages for deeper access  
✅ **RBAC Abuse**: Exploiting overly permissive Kubernetes permissions  
✅ **Backdoor Injection**: Modifying deployments to establish persistence  
✅ **Detection Challenges**: Why GitOps attacks are hard to detect  
✅ **Defense in Depth**: Multi-layered security controls to prevent attacks

## Quick Start

### For Participants

1. **Prerequisites**: Complete Challenge #2 to extract `.env.production`
2. **Setup**: `make setup-challenge4` (creates production cluster + ArgoCD)
3. **Attack**: Follow [ATTACK-GUIDE.md](./ATTACK-GUIDE.md)
4. **Learn**: Read [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)
5. **Defend**: Study [SECURITY-GUIDE.md](./SECURITY-GUIDE.md)

### For Organizers

1. **Setup Environment**: `make setup-challenge4`
2. **Verify**: `make verify-challenge4`
3. **Test Attack**: Follow [ATTACK-GUIDE.md](./ATTACK-GUIDE.md)
4. **Apply Security**: `make apply-challenge4-security`
5. **Test Prevention**: `make test-challenge4-attack`

## File Structure

```
challenges/challenge4/
├── README.md                          # This file
├── SETUP.md                           # Environment setup (organizers)
├── ATTACK-GUIDE.md             # Attack walkthrough (participants)
├── ATTACK-ANALYSIS.md                 # Technical analysis & real-world examples
├── SECURITY-GUIDE.md                  # Detection & prevention strategies
│
├── argocd/                            # ArgoCD configuration
│   ├── argocd-values.yaml             # Helm values (vulnerable!)
│   ├── recipe-api-application.yaml    # ArgoCD Application manifest
│   ├── vulnerable-rbac.yaml           # Excessive RBAC permissions
│   ├── namespace.yaml                 # Namespace definitions
│   └── challenge4-flag-secret.yaml    # Final registry credentials
│
├── production-manifests-sample/       # GitOps repository
│   ├── README.md                      # Repository setup instructions
│   └── recipe-api/                    # Application manifests
│       ├── deployment.yaml            # Kubernetes Deployment
│       ├── service.yaml               # Kubernetes Service
│       ├── serviceaccount.yaml        # ServiceAccount & Secrets
│       └── kustomization.yaml         # Kustomize configuration
│
├── attack-payloads/                   # Malicious workloads
│   ├── README.md                      # Attack payload documentation
│   ├── backdoored-deployment.yaml     # Deployment with injected backdoor
│   ├── malicious-pod.yaml             # Cryptocurrency miner pod
│   └── data-exfil-cronjob.yaml        # Secret exfiltration CronJob
│
├── security/                          # Prevention & detection
│   ├── README.md                      # Security controls overview
│   ├── kyverno-policies/              # Admission control policies
│   │   ├── require-image-signature.yaml
│   │   ├── restrict-privileged-containers.yaml
│   │   └── restrict-high-resources.yaml
│   ├── network-policies/              # Network segmentation
│   │   └── deny-egress-default.yaml
│   ├── rbac/                          # Least-privilege RBAC
│   │   └── least-privilege-argocd.yaml
│   └── falco-rules/                   # Runtime detection
│       └── gitops-attacks.yaml
│
└── scripts/                           # Helper scripts
    ├── setup-argocd-token.sh       # Token configuration utility
    └── test-leaked-token.sh
```

## Challenge Workflow

### Phase 1: Credential Extraction (Challenge 2)

Extract ArgoCD credentials from `.env.production` in container image git history:

```env
ARGOCD_SERVER=argocd-server.argocd.svc.cluster.local
ARGOCD_AUTH_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
ARGOCD_APP_NAME=recipe-api-production
```

### Phase 2: Access GitOps Pipeline

Use stolen credentials to access ArgoCD Web UI or API:

```bash
# Web UI
https://argocd.sc.local:31443

# CLI
argocd login argocd.sc.local:31443 --auth-token=$ARGOCD_AUTH_TOKEN --insecure
```

### Phase 3: Modify Deployment

Clone production manifests, inject backdoor, commit and push:

```bash
git clone http://gitea-prod.sc.local:31080/sc-admin/production-manifests.git
# Modify deployment.yaml with malicious payload
git commit -am "Update deployment configuration"
git push origin main
```

### Phase 4: Automatic Deployment

ArgoCD auto-syncs the malicious changes to production:

```bash
# Watch deployment
argocd app watch recipe-api-production

# Verify backdoor deployed
kubectl -n production get pods -l app=recipe-api -o yaml | grep -A5 securityContext
```

### Phase 5: deep dive

Extract the flag from the production cluster:

```bash
kubectl --context kind-production-cluster \
  -n production get secret challenge4-flag \
  -o jsonpath='{.data.flag}' | base64 -d
```

## Vulnerability Summary

| Vulnerability | Impact | Severity |
|---------------|--------|----------|
| **Leaked ArgoCD Token** | Full GitOps pipeline access | Critical |
| **Cluster-Admin RBAC** | Unlimited Kubernetes permissions | Critical |
| **No Admission Policies** | Malicious pods not blocked | High |
| **No Network Policies** | Reverse shells & exfil allowed | High |
| **Auto-Sync Enabled** | No manual review before deployment | Medium |
| **No Image Verification** | Unsigned images allowed | Medium |

## Security Controls (Prevention)

1. **Secrets Management**: External secret stores (Vault, AWS Secrets Manager)
2. **Least-Privilege RBAC**: Namespace-scoped roles, minimal permissions
3. **Admission Policies**: Kyverno/OPA blocking dangerous pods
4. **Network Policies**: Default-deny egress with explicit allow-list
5. **Image Signing**: Require signed images (Cosign/Sigstore)
6. **Manual Approval**: Disable auto-sync for production
7. **Runtime Monitoring**: Falco for anomaly detection
8. **Audit Logging**: Comprehensive logging and alerting

## Real-World Examples

- **SolarWinds (2020)**: Build pipeline compromise affecting 18,000+ orgs
- **Codecov (2021)**: CI/CD credential theft via modified script
- **Kubernetes Cryptojacking**: Widespread cryptominer deployments

See [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md) for detailed case studies.

## Makefile Commands

```bash
# Setup
make setup-production-cluster   # Create production KinD cluster
make setup-argocd               # Install ArgoCD
make setup-challenge4           # Complete setup (cluster + ArgoCD)

# Verification
make verify-challenge4          # Verify setup

# Security
make apply-challenge4-security  # Apply security controls
make test-challenge4-attack     # Test that attacks are blocked

# Cleanup
make clean-challenge4           # Delete production cluster
```

## Documentation

- **[SETUP.md](./SETUP.md)**: Environment setup instructions (organizers)
- **[ATTACK-GUIDE.md](./ATTACK-GUIDE.md)**: Step-by-step attack walkthrough
- **[ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)**: Technical analysis & real-world examples
- **[SECURITY-GUIDE.md](./SECURITY-GUIDE.md)**: Detection & prevention strategies

## Support

**Need Help?**
- Setup issues: See [SETUP.md](./SETUP.md)
- Attack execution: See [ATTACK-GUIDE.md](./ATTACK-GUIDE.md)
- Understanding the attack: See [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)
- Prevention strategies: See [SECURITY-GUIDE.md](./SECURITY-GUIDE.md)

## Credits

Created as part of the Supply Chain Security deep dive project.

**Repository**: https://github.com/sherine-k/supply-chain-dd  
**Challenge Author**: Claude Code & Sherine K
