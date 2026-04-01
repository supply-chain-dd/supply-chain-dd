# Tekton Patched - Secure Configuration

This directory contains **secured versions** of the Tekton pipeline resources that use minimal service accounts and defense-in-depth security controls.

## 🔄 What Changed from `tekton/` (Vulnerable Version)

### Key Security Improvements

| Aspect | Vulnerable (`tekton/`) | Secure (`tekton-patched/`) |
|--------|------------------------|---------------------------|
| **ServiceAccount** | Uses `default` SA (has secret access) | Uses `pr-pipeline-readonly` SA (NO secret access) |
| **RBAC** | Default SA can read all secrets | pr-pipeline-readonly cannot access secrets |
| **PipelineRun** | No serviceAccountName specified | Explicitly sets `serviceAccountName: pr-pipeline-readonly` |
| **Default SA RBAC** | Has dangerous permissions (lines 158-185) | **Removed** - default SA has no permissions |
| **Annotations** | None | Security annotations for tracking |

### Specific Changes

#### 1. **triggers/secure-eventlistener.yaml**

**CRITICAL CHANGE**: PipelineRun template now specifies ServiceAccount

```yaml
# Before (tekton/triggers/vulnerable-eventlistener.yaml):
kind: PipelineRun
spec:
  pipelineRef:
    name: pr-quality-check-pipeline
  # No serviceAccountName - uses default SA with secret access!

# After (tekton-patched/triggers/secure-eventlistener.yaml):
kind: PipelineRun
spec:
  serviceAccountName: pr-pipeline-readonly  # ✅ Secure SA
  pipelineRef:
    name: pr-quality-check-pipeline
```

**REMOVED**: Dangerous RBAC for default ServiceAccount
- Lines 158-185 in vulnerable version granted default SA ability to read all secrets
- Completely removed in secure version
- Default SA now has zero permissions

#### 2. **pipelines/secure-pr-quality-pipeline.yaml**

- Added security annotations
- Updated comments to explain defense-in-depth
- Pipeline logic unchanged (inherits SA from PipelineRun)

#### 3. **tasks/secure-quality-check-task.yaml**

- Still executes `go run` on untrusted code (for CTF demonstration)
- Added extensive comments explaining how security controls prevent attack
- Task shows security context in logs
- Explains what happens when malicious code runs

#### 4. **tasks/supporting-tasks.yaml**

- Minimal changes
- Added annotations for security tracking
- Tasks inherit SA from PipelineRun

---

## 🚀 Deployment

### Option 1: Deploy Secure Version (Recommended)

```bash
# 1. Ensure security RBAC is deployed
kubectl apply -f security/rbac/minimal-serviceaccounts.yaml

# 2. Deploy secure Tekton resources
kubectl apply -f tekton-patched/tasks/
kubectl apply -f tekton-patched/pipelines/
kubectl apply -f tekton-patched/triggers/

# 3. Verify ServiceAccounts
kubectl get sa -n ctf-challenge
# Should show: pr-pipeline-readonly, main-pipeline, security-auditor
```

### Option 2: Compare Vulnerable vs Secure

```bash
# Deploy vulnerable version (for attack demonstration)
kubectl apply -f tekton/

# Test the attack (follows CTF challenge guide)
# Flag gets stolen successfully

# Deploy security controls
make apply-prevention-policies

# Replace with secure version
kubectl delete -f tekton/
kubectl apply -f tekton-patched/

# Test the attack again
# Attack is now blocked at multiple layers!
```

---

## 🧪 Testing the Secure Configuration

### Test 1: Verify ServiceAccount is Used

```bash
# Create a test PipelineRun
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: test-secure-sa
  namespace: ctf-challenge
spec:
  serviceAccountName: pr-pipeline-readonly
  pipelineRef:
    name: pr-quality-check-pipeline
  params:
  - name: pr-repo-url
    value: http://gitea.gitea.svc.cluster.local/ctf/victim-repo.git
  - name: pr-sha
    value: main
  - name: pr-number
    value: "1"
  workspaces:
  - name: source
    emptyDir: {}
EOF

# Check which SA was used
kubectl get pipelinerun test-secure-sa -n ctf-challenge -o jsonpath='{.spec.serviceAccountName}'
# Expected: pr-pipeline-readonly
```

### Test 2: Verify Kyverno Allows It

If you have Kyverno policies applied:

```bash
# This should be ALLOWED (correct SA)
kubectl apply -f tekton-patched/triggers/secure-eventlistener.yaml

# Check policy report
kubectl get policyreport -n ctf-challenge -o json | \
  jq '.items[].results[] | select(.resources[0].name=="pr-quality-check-listener")'
```

### Test 3: Simulate Attack and Verify It's Blocked

```bash
# Create a test pipeline run that tries to steal secrets
# (Using the same malicious code from challenges/)

# 1. Deploy the secure pipeline
kubectl apply -f tekton-patched/

# 2. Run pipeline with malicious code
tkn pipeline start pr-quality-check-pipeline \
  --param pr-repo-url=<repo-with-malicious-code> \
  --param pr-sha=main \
  --param pr-number=999 \
  --workspace name=source,emptyDir="" \
  --showlog

# 3. Check logs - you'll see:
# - Code executes (go run still runs)
# - K8s API call to get secret returns: 403 Forbidden ✅
# - HTTP POST to attacker.com times out ✅
# - Attack blocked!
```

---

## 📊 Defense-in-Depth Layers

```
┌─────────────────────────────────────────────────────────┐
│ Attack: Malicious PR code tries to steal secrets        │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Layer 1: Kyverno (Policy Enforcement)                   │
│ ✅ Validates serviceAccountName: pr-pipeline-readonly   │
│ ⚠️  Warns on 'go run' usage                             │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Layer 2: RBAC (Access Control)                          │
│ ❌ pr-pipeline-readonly CANNOT read secrets             │
│ ❌ K8s API returns: 403 Forbidden                       │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Layer 3: NetworkPolicy (Exfiltration Prevention)        │
│ ❌ External egress to attacker.com: Connection timeout  │
│ ✅ Internal Gitea access: Allowed                       │
└─────────────────────────────────────────────────────────┘
                          ↓
                   ✅ Attack Blocked!
```

---

## 🎓 Learning Objectives

### For CTF Participants

1. **Experience the vulnerability** (use `tekton/`)
   - Deploy vulnerable version
   - Run the attack
   - Steal the flag

2. **Understand the fix** (use `tekton-patched/`)
   - Deploy secure version
   - Try the same attack
   - See it get blocked

3. **Learn defense-in-depth**
   - Multiple layers protect against attack
   - Even if code execution happens, damage is prevented
   - No single point of failure

### For Security Engineers

1. **ServiceAccount separation** matters
   - PR pipelines vs main branch pipelines
   - Untrusted code vs trusted code
   - Minimal permissions by default

2. **Defense-in-depth** is essential
   - Don't rely on a single control
   - Combine policy + RBAC + network controls
   - Monitor and audit all layers

3. **Real-world applicability**
   - Same principles apply to GitHub Actions, GitLab CI, etc.
   - ServiceAccounts = OIDC tokens in cloud CI/CD
   - Network policies = VPC restrictions

---

## 📁 File Comparison

### Quick Diff

```bash
# See what changed
diff -u tekton/triggers/vulnerable-eventlistener.yaml \
        tekton-patched/triggers/secure-eventlistener.yaml

# Key differences:
# + serviceAccountName: pr-pipeline-readonly (line ~69)
# - Lines 158-185 (dangerous default SA RBAC) removed
```

### File Mapping

| Vulnerable Version | Secure Version | Main Change |
|-------------------|----------------|-------------|
| `tekton/triggers/vulnerable-eventlistener.yaml` | `tekton-patched/triggers/secure-eventlistener.yaml` | ✅ Added `serviceAccountName: pr-pipeline-readonly` to PipelineRun<br>❌ Removed dangerous default SA RBAC |
| `tekton/pipelines/vulnerable-pr-quality-pipeline.yaml` | `tekton-patched/pipelines/secure-pr-quality-pipeline.yaml` | Added security annotations and comments |
| `tekton/tasks/vulnerable-quality-check-task.yaml` | `tekton-patched/tasks/secure-quality-check-task.yaml` | Added security context logging and defense explanations |
| `tekton/tasks/supporting-tasks.yaml` | `tekton-patched/tasks/supporting-tasks.yaml` | Added security annotations |

---

## 🔗 Related Resources

- **Attack Analysis**: [`ATTACK-ANALYSIS.md`](../ATTACK-ANALYSIS.md)
- **Security Guide**: [`SECURITY-GUIDE.md`](../SECURITY-GUIDE.md)
- **RBAC Definitions**: [`security/rbac/minimal-serviceaccounts.yaml`](../security/rbac/minimal-serviceaccounts.yaml)
- **Network Policies**: [`security/network-policies/`](../security/network-policies/)
- **Kyverno Policies**: [`security/kyverno-policies/`](../security/kyverno-policies/)

---

## 💡 Best Practices Demonstrated

1. ✅ **Explicit ServiceAccount specification** in PipelineRuns
2. ✅ **Least privilege RBAC** - only grant what's needed
3. ✅ **Separate SAs for different trust levels** (PR vs main)
4. ✅ **Remove dangerous default permissions**
5. ✅ **Use named secrets** in RBAC (not wildcard)
6. ✅ **Combine multiple security layers** (defense-in-depth)
7. ✅ **Document security decisions** with annotations
8. ✅ **Monitor and audit** with Kyverno PolicyReports

---

## 🎯 Summary

The `tekton-patched/` directory demonstrates **how to secure Tekton pipelines** that process untrusted code:

**Single most important change:**
```yaml
# In TriggerTemplate resourcetemplates:
spec:
  serviceAccountName: pr-pipeline-readonly  # ← This line prevents the attack
```

**Combined with:**
- RBAC that denies secret access
- Network policies that block exfiltration
- Kyverno policies that validate configuration
- Comprehensive monitoring and auditing

**Result:** Even if malicious code executes (via `go run`), the attack fails at multiple layers.

This is the **production-ready** configuration. Use this as a template for your own Tekton pipelines!
