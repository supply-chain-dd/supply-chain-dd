# Deployment Guide - Secure Tekton Configuration

Quick reference for deploying the secure Tekton pipeline configuration.

## 🚀 Quick Deploy

### Option 1: Automated (Recommended)

```bash
# Deploy complete secure setup
make setup-ctf-challenge-secure

# Apply network policies and Kyverno rules
make apply-prevention-policies

# Verify everything
make verify-security
```

### Option 2: Manual Step-by-Step

```bash
# 1. Create namespace
kubectl create namespace ctf-challenge

# 2. Deploy minimal ServiceAccounts (RBAC)
kubectl apply -f security/rbac/minimal-serviceaccounts.yaml

# 3. Deploy secure Tekton resources
kubectl apply -f tekton-patched/tasks/
kubectl apply -f tekton-patched/pipelines/
kubectl apply -f tekton-patched/triggers/

# 4. Create flag secret
kubectl create secret generic ctf-flag \
  --from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
  -n ctf-challenge

# 5. Apply network policies (optional but recommended)
kubectl apply -f security/network-policies/

# 6. Apply Kyverno policies (optional but recommended)
kubectl apply -f security/kyverno-policies/

# 7. Verify deployment
kubectl get sa,pipeline,task,eventlistener -n ctf-challenge
```

---

## ✅ Verification Checklist

```bash
# 1. Check ServiceAccounts exist
kubectl get sa -n ctf-challenge
# Expected: pr-pipeline-readonly, main-pipeline, tekton-triggers-sa, default

# 2. Verify pr-pipeline-readonly has NO secret access
kubectl auth can-i get secrets \
  --as=system:serviceaccount:ctf-challenge:pr-pipeline-readonly \
  -n ctf-challenge
# Expected: no

# 3. Check Pipeline exists
kubectl get pipeline -n ctf-challenge
# Expected: pr-quality-check-pipeline

# 4. Check Tasks exist
kubectl get task -n ctf-challenge
# Expected: git-clone, print-info, print-results, quality-check-task

# 5. Check EventListener exists
kubectl get eventlistener -n ctf-challenge
# Expected: pr-quality-check-listener

# 6. Verify flag secret exists
kubectl get secret ctf-flag -n ctf-challenge
# Expected: ctf-flag (Opaque, 1 data field)
```

---

## 🧪 Test the Secure Configuration

### Test 1: Manual Pipeline Run

```bash
# Create a test PipelineRun
kubectl create -f - <<EOF
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: test-secure-pipeline
  namespace: ctf-challenge
spec:
  serviceAccountName: pr-pipeline-readonly
  pipelineRef:
    name: pr-quality-check-pipeline
  params:
  - name: pr-repo-url
    value: https://github.com/example/test-repo.git
  - name: pr-sha
    value: main
  - name: pr-number
    value: "1"
  workspaces:
  - name: source
    emptyDir: {}
EOF

# Watch the pipeline run
tkn pipelinerun logs test-secure-pipeline -f -n ctf-challenge
```

### Test 2: Verify RBAC Blocks Secret Access

```bash
# Create a test pod with pr-pipeline-readonly SA
kubectl run test-rbac -n ctf-challenge \
  --image=curlimages/curl:latest \
  --serviceaccount=pr-pipeline-readonly \
  --rm -it --restart=Never -- sh

# Inside the pod, try to access secrets
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -k -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/ctf-challenge/secrets/ctf-flag

# Expected output: HTTP 403 Forbidden
```

### Test 3: Verify Network Policy Blocks Exfiltration

```bash
# Create test pod in ctf-challenge namespace
kubectl run test-netpol -n ctf-challenge \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never -- sh

# Try to access external server
curl -m 5 http://google.com

# Expected: Connection timeout

# Try internal Gitea (should work)
curl -m 5 http://gitea.gitea.svc.cluster.local:3000

# Expected: Gitea homepage HTML
```

---

## 🔄 Migration from Vulnerable to Secure

If you have the vulnerable version deployed:

```bash
# 1. Save any important data
kubectl get pipelinerun -n ctf-challenge -o yaml > pipelinerun-backup.yaml

# 2. Delete vulnerable version
kubectl delete -f tekton/

# 3. Deploy security RBAC first
kubectl apply -f security/rbac/minimal-serviceaccounts.yaml

# 4. Deploy secure version
kubectl apply -f tekton-patched/

# 5. Apply additional security controls
make apply-prevention-policies

# 6. Verify
make verify-security
```

---

## 📊 What Gets Deployed

### ServiceAccounts (from security/rbac/)

| ServiceAccount | Purpose | Permissions |
|----------------|---------|-------------|
| `pr-pipeline-readonly` | For untrusted PR pipelines | Read ConfigMaps only, NO secret access |
| `main-pipeline` | For trusted main branch | Read specific named secrets only |
| `security-auditor` | For monitoring tools | Read-only cluster-wide access |
| `tekton-triggers-sa` | For EventListener | Create PipelineRuns, read webhook secret |

### Pipelines

| Pipeline | Description |
|----------|-------------|
| `pr-quality-check-pipeline` | Quality check pipeline with security controls |

### Tasks

| Task | Description |
|------|-------------|
| `git-clone` | Clone git repositories |
| `print-info` | Display PR information |
| `quality-check-task` | Run quality checks (still executes code, but secured) |
| `print-results` | Display results |

### Triggers

| Resource | Description |
|----------|-------------|
| `pr-quality-check-listener` | EventListener for PR webhooks |
| `pr-quality-binding` | Extract data from webhook payload |
| `pr-quality-template` | Template for creating PipelineRuns |

---

## 🔧 Customization

### Use Different ServiceAccount

Edit `tekton-patched/triggers/secure-eventlistener.yaml`:

```yaml
# Line ~69 in TriggerTemplate
spec:
  serviceAccountName: your-custom-sa  # Change this
```

### Add More Tasks to Pipeline

Edit `tekton-patched/pipelines/secure-pr-quality-pipeline.yaml`:

```yaml
tasks:
  # ... existing tasks ...
  - name: your-new-task
    runAfter: ["run-quality-checks"]
    taskRef:
      name: your-task-name
```

### Change Flag Secret

```bash
kubectl create secret generic ctf-flag \
  --from-literal=flag='YOUR_CUSTOM_FLAG' \
  -n ctf-challenge \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 🐛 Troubleshooting

### Problem: PipelineRun uses wrong ServiceAccount

**Check:**
```bash
kubectl get pipelinerun <name> -n ctf-challenge -o jsonpath='{.spec.serviceAccountName}'
```

**Fix:**
```bash
# Ensure TriggerTemplate specifies serviceAccountName
kubectl edit triggertemplate pr-quality-template -n ctf-challenge
```

### Problem: Tasks can't access workspace

**Check:**
```bash
kubectl describe pipelinerun <name> -n ctf-challenge
```

**Fix:**
Ensure workspace is defined in PipelineRun spec.

### Problem: Kyverno blocks the PipelineRun

**Check:**
```bash
kubectl get policyreport -n ctf-challenge -o yaml
```

**Fix:**
Ensure you're using `pr-pipeline-readonly` ServiceAccount in the PipelineRun.

### Problem: Network policy blocks legitimate traffic

**Check:**
```bash
kubectl get networkpolicy -n ctf-challenge
kubectl describe networkpolicy ctf-challenge-egress-restriction -n ctf-challenge
```

**Fix:**
Add allowed egress destinations in `security/network-policies/tekton-egress-restriction.yaml`.

---

## 📚 Documentation

- **Overview**: [`tekton-patched/README.md`](README.md)
- **Security Guide**: [`SECURITY-GUIDE.md`](../SECURITY-GUIDE.md)
- **Attack Analysis**: [`ATTACK-ANALYSIS.md`](../ATTACK-ANALYSIS.md)
- **RBAC Definitions**: [`security/rbac/minimal-serviceaccounts.yaml`](../security/rbac/minimal-serviceaccounts.yaml)

---

## 🎯 Production Deployment Checklist

Before deploying to production:

- [ ] Review ServiceAccount permissions
- [ ] Audit RBAC rules (use `kubectl auth can-i`)
- [ ] Apply network policies in all namespaces
- [ ] Deploy Kyverno policies in enforce mode
- [ ] Set up monitoring (Kubescape, Audicia)
- [ ] Configure alerting for policy violations
- [ ] Test disaster recovery procedures
- [ ] Document incident response plan
- [ ] Enable audit logging
- [ ] Regular security scans (weekly)

---

## 💡 Pro Tips

1. **Test in stages**: Deploy vulnerable → attack → deploy secure → verify blocked
2. **Use labels**: Add `security/trust-level` labels to all resources
3. **Monitor continuously**: Set up Kyverno PolicyReports monitoring
4. **Separate environments**: Dev (audit mode) → Staging (enforce) → Prod (enforce + monitor)
5. **Document exceptions**: If you need to bypass a policy, document why

---

**Ready to deploy?** Run: `make setup-ctf-challenge-secure` 🚀
