# Attack Payloads for Challenge 4

This directory contains example malicious payloads that demonstrate GitOps pipeline compromise attacks.

## Attack Scenarios

### 1. Backdoored Deployment (`backdoored-deployment.yaml`)

**Attack Vector**: Modify the existing `recipe-api` deployment to inject backdoor code.

**Malicious Changes**:
- **Reverse Shell**: Connects back to attacker-controlled server
- **Data Exfiltration**: Periodically steals Kubernetes secrets
- **Privilege Escalation**: Runs as root with dangerous capabilities
- **Command Injection**: Replaces legitimate startup command

**Detection Difficulty**: Medium (deployment changes might be noticed)

**Impact**: High - Full control over application, secret theft, persistence

### 2. Malicious Pod (`malicious-pod.yaml`)

**Attack Vector**: Deploy a new pod disguised as legitimate infrastructure.

**Malicious Behavior**:
- **Cryptocurrency Mining**: Consumes cluster resources for profit
- **Disguised as "cache-warmer"**: Uses innocent-sounding name
- **High Resource Usage**: Requests significant CPU/memory

**Detection Difficulty**: Low (unusual resource usage, new workload)

**Impact**: Medium - Resource abuse, increased cloud costs

### 3. Data Exfiltration CronJob (`data-exfil-cronjob.yaml`)

**Attack Vector**: Deploy a scheduled job disguised as a backup utility.

**Malicious Behavior**:
- **Periodic Execution**: Runs every 5 minutes
- **Secret Theft**: Extracts all secrets, configmaps, service accounts
- **Stealthy**: Uses legitimate-looking kubectl commands
- **Automated**: No manual intervention needed

**Detection Difficulty**: Medium (CronJob might blend in with ops tasks)

**Impact**: Critical - Complete secret compromise, ongoing theft

## Using These Payloads

### Method 1: Via Git (Recommended for the deep dive)

```bash
# Clone the production-manifests repository
git clone http://gitea-prod.sc.local:31080/sc-admin/production-manifests.git
cd production-manifests/recipe-api

# Replace deployment with backdoored version
cp /path/to/backdoored-deployment.yaml deployment.yaml

# Commit and push
git add deployment.yaml
git commit -m "Update deployment resource limits"
git push origin main

# ArgoCD will automatically sync the malicious changes!
```

### Method 2: Via ArgoCD CLI

```bash
# Using stolen ArgoCD credentials from .env.production
export ARGOCD_AUTH_TOKEN=eyJhbGci...
export ARGOCD_SERVER=argocd.sc.local:31080

# Deploy malicious pod directly
argocd app create malicious-cache \
  --repo http://gitea-http.gitea.svc.cluster.local:3000/sc-admin/attack-manifests.git \
  --path malicious-pod \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production
```

### Method 3: Via kubectl (with stolen kubeconfig)

```bash
# Using credentials from .env.production
kubectl --server=https://production-cluster-control-plane:6443 \
  --token=$KUBE_TOKEN \
  apply -f malicious-pod.yaml
```

## Detection Indicators

Look for these anomalies:

1. **Resource Usage Spikes**
   - Sudden CPU/memory increases
   - New high-resource pods

2. **Network Anomalies**
   - Outbound connections to unusual IPs
   - High egress traffic volumes

3. **RBAC Abuse**
   - Service accounts accessing unexpected resources
   - Elevated permission usage

4. **Git Activity**
   - Deployment changes from unknown users
   - Commits at unusual times
   - Suspicious commit messages

5. **Runtime Behavior**
   - Unexpected processes (bash, curl, nc)
   - Shell spawning from containers
   - Secret access patterns

## Remediation

If you detect these attacks:

1. **Immediate Actions**:
   - Revoke compromised ArgoCD tokens
   - Rotate all Kubernetes service account tokens
   - Delete malicious workloads
   - Revert Git repository to last known good state

2. **Investigate**:
   - Check Kubernetes audit logs
   - Review ArgoCD sync history
   - Analyze git commit history
   - Identify initial compromise vector

3. **Prevent Recurrence**:
   - Implement admission policies (Kyverno/OPA)
   - Enable network policies
   - Apply least-privilege RBAC
   - Require image signatures
   - Enable runtime monitoring (Falco)

See `../SECURITY-GUIDE.md` for detailed prevention strategies.

## Educational Value

These payloads demonstrate:
- Real-world attack techniques used in actual breaches
- How GitOps can be weaponized
- The importance of admission controls
- Detection challenges in Kubernetes environments
- Defense-in-depth security strategies

## References

- [SolarWinds Supply Chain Attack](https://www.crowdstrike.com/blog/sunburst-malware-technical-analysis/)
- [Codecov Bash Uploader Compromise](https://about.codecov.io/security-update/)
- [Kubernetes Secret Theft Techniques](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
- [GitOps Security Best Practices](https://github.com/open-gitops/project/blob/main/PRINCIPLES.md)
