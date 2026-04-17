# Challenge 4: GitOps Pipeline Compromise - Security Guide

This guide explains how to detect and prevent GitOps pipeline attacks demonstrated in Challenge 4.

## Table of Contents

1. [Detection Mechanisms](#detection-mechanisms)
2. [Prevention Controls](#prevention-controls)
3. [Implementation Guide](#implementation-guide)
4. [Testing Security Controls](#testing-security-controls)
5. [Incident Response](#incident-response)

## Detection Mechanisms

### 1. Git Activity Monitoring

**What to Monitor**:
- Commit authors and timestamps
- Commit messages (look for "debug", "temp", "hotfix")
- File changes (especially security-sensitive files)
- Push events from unusual IPs

**Implementation**:

```bash
# Gitea webhook to Slack/PagerDuty
# Configure in Gitea repository settings
curl -X POST $WEBHOOK_URL \
  -H "Content-Type: application/json" \
  -d '{
    "text": "⚠️ Production manifest modified",
    "fields": [
      {"title": "Repo", "value": "production-manifests"},
      {"title": "Author", "value": "$GIT_AUTHOR"},
      {"title": "Message", "value": "$GIT_COMMIT_MESSAGE"}
    ]
  }'
```

**Alerting Rules**:
- Any commit outside business hours → Alert
- Commits from non-approved authors → Block
- Security context changes (runAsUser, privileged) → Alert + Review

### 2. Kubernetes Audit Logging

**Enable Audit Logging** (for production cluster):

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log all Deployment modifications
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "apps"
        resources: ["deployments"]
    namespaces: ["production"]
  
  # Log privilege escalation attempts
  - level: RequestResponse
    verbs: ["create", "update"]
    resources:
      - group: ""
        resources: ["pods"]
    omitStages: []
```

**Query Audit Logs**:

```bash
# Find deployment modifications
kubectl logs -n kube-system kube-apiserver-xxx | \
  jq 'select(.verb=="update" and .objectRef.resource=="deployments")'

# Find pods running as root
kubectl logs -n kube-system kube-apiserver-xxx | \
  jq 'select(.requestObject.spec.securityContext.runAsUser==0)'
```

**Tools**:
- **Falco**: Real-time audit log analysis
- **Audicia**: RBAC abuse detection
- **Kubescape**: Compliance scanning

### 3. Runtime Detection (Falco)

**Install Falco**:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set falco.grpc.enabled=true \
  --set falco.grpcOutput.enabled=true

# Add custom rules
kubectl create cm falco-rules -n falco \
  --from-file=challenges/challenge4/security/falco-rules/gitops-attacks.yaml

kubectl rollout restart -n falco daemonset/falco
```

**Key Detections**:
- Reverse shells: `proc.name in (nc, bash) and proc.args contains "/dev/tcp/"`
- Cryptomining: `proc.name in (xmrig) or proc.cmdline contains "stratum+tcp"`
- Kubectl usage: `proc.name = kubectl and container.id != host`
- Secret access: `fd.name startswith "/var/run/secrets/" and proc.name not in (allowed_apps)`

**Alert Forwarding**:

```bash
# Falcosidekick for Slack/PagerDuty integration
helm install falcosidekick falcosecurity/falcosidekick \
  --set config.slack.webhookurl=$SLACK_WEBHOOK
```

### 4. ArgoCD Audit Logs

**Enable ArgoCD Audit**:

```yaml
# argocd-cm ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  application.auditLog.enabled: "true"
```

**Monitor ArgoCD Events**:

```bash
# Watch sync operations
argocd app logs recipe-api-production --follow

# Query application history
argocd app history recipe-api-production

# Check who synced the application
kubectl logs -n argocd deployment/argocd-server | \
  grep "sync operation"
```

## Prevention Controls

### 1. Secrets Management

**Never Commit Secrets to Git!**

Use external secret stores:

**Option A: Kubernetes External Secrets Operator**:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system --create-namespace

# Create SecretStore pointing to Vault/AWS Secrets Manager
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: production
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "production-role"
EOF
```

**Option B: Sealed Secrets**:

```bash
# Install Sealed Secrets controller
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system

# Encrypt secrets before committing to Git
echo -n 'my-secret-password' | \
  kubeseal --raw --scope strict --namespace production
```

**Best Practices**:
- Rotate secrets regularly (30-90 days)
- Use short-lived tokens when possible
- Implement token expiration
- Audit secret access

### 2. Least-Privilege RBAC

**Apply Secure RBAC**:

```bash
kubectl apply -f challenges/challenge4/security/rbac/least-privilege-argocd.yaml
```

**Key Principles**:
- Namespace-scoped `Role` instead of `ClusterRole`
- Only necessary verbs (avoid wildcards)
- Read-only where possible
- No secret write access

**Example Secure Role**:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-deployer-production
  namespace: production
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]  # Read-only!
```

### 3. Admission Policies (Kyverno)

**Install Kyverno**:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

# Apply policies
kubectl apply -f challenges/challenge4/security/kyverno-policies/
```

**Critical Policies**:

1. **Require Non-Root Containers**:
```yaml
- name: require-non-root
  validate:
    message: "Containers must run as non-root user"
    pattern:
      spec:
        containers:
        - securityContext:
            runAsNonRoot: true
```

2. **Drop All Capabilities**:
```yaml
- name: drop-all-capabilities
  validate:
    message: "Containers must drop ALL capabilities"
    pattern:
      spec:
        containers:
        - securityContext:
            capabilities:
              drop: [ALL]
```

3. **Restrict Resource Limits** (anti-cryptomining):
```yaml
- name: limit-cpu-requests
  validate:
    message: "CPU request exceeds 1 core - cryptomining suspected"
    deny:
      conditions:
        - key: "{{request.object.spec.containers[].resources.requests.cpu}}"
          operator: GreaterThan
          value: "1000m"
```

4. **Require Image Signatures** (Cosign):
```yaml
- name: verify-image-signature
  verifyImages:
  - imageReferences: ["*"]
    attestors:
    - entries:
      - keys:
          publicKeys: |-
            -----BEGIN PUBLIC KEY-----
            ...
            -----END PUBLIC KEY-----
```

### 4. Network Policies

**Apply Deny-All Default**:

```bash
kubectl apply -f challenges/challenge4/security/network-policies/deny-egress-default.yaml
```

**Policy Structure**:

```yaml
# Default deny all egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-egress-default
  namespace: production
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress: []

---
# Allow-list specific egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-recipe-api-egress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: recipe-api
  egress:
    - to: [{podSelector: {matchLabels: {app: postgresql}}}]
      ports: [{protocol: TCP, port: 5432}]
    - to: [{namespaceSelector: {matchLabels: {name: kube-system}}}]
      ports: [{protocol: UDP, port: 53}]
```

**This Blocks**:
- Reverse shells to external IPs
- Data exfiltration via HTTPS
- Cryptomining pool connections

### 5. GitOps Approval Gates

**Disable Auto-Sync for Production**:

```yaml
# argocd-cm ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  # Disable auto-sync globally
  application.resourceTrackingMethod: annotation
  resource.customizations: |
    admissionregistration.k8s.io/MutatingWebhookConfiguration:
      ignoreDifferences: |
        jsonPointers:
        - /webhooks/0/clientConfig/caBundle
```

**Require Manual Approval**:

```bash
# Developers can preview changes
argocd app diff recipe-api-production

# Operations team approves and syncs
argocd app sync recipe-api-production --prune
```

**Pull Request Reviews**:
- Require 2+ approvals for production manifests
- Automated security scans in CI (Kubescape, Trivy)
- CODEOWNERS file for critical paths

## Implementation Guide

### Quick Setup (All Controls)

```bash
# Switch to production cluster
kubectl config use-context kind-ctf-production-cluster

# Apply all security controls
make apply-challenge4-security

# Verify
make verify-challenge4
```

### Step-by-Step Setup

**1. Install Kyverno**:
```bash
kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.10.0/install.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=300s
kubectl apply -f challenges/challenge4/security/kyverno-policies/
```

**2. Apply Network Policies**:
```bash
kubectl apply -f challenges/challenge4/security/network-policies/
```

**3. Update ArgoCD RBAC**:
```bash
kubectl delete clusterrolebinding argocd-controller-admin  # Remove vulnerable binding
kubectl apply -f challenges/challenge4/security/rbac/least-privilege-argocd.yaml
```

**4. Install Falco**:
```bash
helm install falco falcosecurity/falco -n falco --create-namespace
kubectl create cm falco-rules -n falco --from-file=challenges/challenge4/security/falco-rules/
kubectl rollout restart -n falco daemonset/falco
```

## Testing Security Controls

### Test Backdoor is Blocked

```bash
# This should be BLOCKED by Kyverno
kubectl apply -f challenges/challenge4/attack-payloads/backdoored-deployment.yaml

# Expected error:
# Error from server: admission webhook denied the request:
# policy recipe-api-production/require-non-root failed
```

### Test Cryptominer is Blocked

```bash
# This should be BLOCKED by resource limits policy
kubectl apply -f challenges/challenge4/attack-payloads/malicious-pod.yaml

# Expected error:
# policy malicious-pod/limit-cpu-requests failed:
# CPU request exceeds maximum allowed (1 core)
```

### Test Network Policies

```bash
# Deploy a test pod
kubectl run -n production test-pod --image=alpine --restart=Never -- sleep 3600

# Try external connection (should FAIL)
kubectl exec -n production test-pod -- wget -O- https://google.com
# Connection timeout

# Try allowed connection (should SUCCEED)
kubectl exec -n production test-pod -- nc -zv postgresql 5432
# Connection succeeded
```

## Incident Response

If you detect a GitOps compromise:

### 1. Contain (Immediate - Minutes)

```bash
# Revoke ArgoCD tokens
kubectl delete secret argocd-deployer-token -n argocd

# Disable ArgoCD sync
argocd app set recipe-api-production --sync-policy none

# Quarantine affected pods
kubectl label pods -n production compromised=true
kubectl scale deployment recipe-api -n production --replicas=0
```

### 2. Investigate (Hours)

```bash
# Git history
git log --all --oneline production-manifests
git show <suspect-commit>

# Kubernetes audit logs
kubectl logs -n kube-system kube-apiserver-xxx | \
  jq 'select(.verb=="update" and .user.username contains "argocd")'

# ArgoCD sync history
argocd app history recipe-api-production

# Falco alerts
kubectl logs -n falco -l app=falco | grep CRITICAL
```

### 3. Eradicate (Days)

```bash
# Git revert malicious commits
git revert <bad-commit-hash>
git push origin main

# Redeploy clean version
argocd app sync recipe-api-production --force --prune

# Rotate all credentials
kubectl delete secret -n production --all
# Re-create with new values

# Patch vulnerabilities
kubectl apply -f challenges/challenge4/security/
```

### 4. Recover (Weeks)

- Apply security controls (Kyverno, NetworkPolicy, RBAC)
- Implement monitoring (Falco, audit logs)
- Conduct security training
- Update runbooks

## Summary

**Critical Controls**:
1. ✅ Secrets in Vault/External Secrets (NOT Git)
2. ✅ Least-privilege RBAC (namespace-scoped)
3. ✅ Admission policies (Kyverno/OPA)
4. ✅ Network policies (deny-all default)
5. ✅ Manual approval for production
6. ✅ Runtime monitoring (Falco)
7. ✅ Audit logging (Kubernetes + ArgoCD)

**Detection Stack**:
- Git activity monitoring
- Kubernetes audit logs
- Falco runtime detection
- Network traffic analysis
- ArgoCD audit logs

**Prevention Stack**:
- External secret management
- Pod Security Standards
- Network segmentation
- Image signing
- GitOps approval gates

## References

- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [NSA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF)
- [Kyverno Best Practices](https://kyverno.io/policies/)
- [Falco Rules Maturity Framework](https://github.com/falcosecurity/rules/blob/main/CONTRIBUTING.md)
