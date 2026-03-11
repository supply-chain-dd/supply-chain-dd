# Tekton Token Theft CTF - Setup Guide

This guide explains how to set up the "Pwn Request" CTF challenge using Tekton Pipelines.

## Quick Start

```bash
# 1. Setup Kubernetes cluster with Tekton
make setup

# 2. Install Tekton resources for CTF
make setup-ctf-challenge

# 3. Create flag secret
kubectl create secret generic ctf-flag \
  --from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
  -n default

# 4. Verify installation
make verify-ctf
```

## Detailed Setup

### Prerequisites

1. **Kubernetes Cluster**
   - kind (recommended for local testing)
   - minikube
   - Any Kubernetes cluster (v1.24+)

2. **Tekton Installation**
   - Tekton Pipelines v0.50.0+
   - Tekton Triggers v0.25.0+

3. **Tools**
   - kubectl
   - tkn (Tekton CLI)
   - git

### Step 1: Create Kubernetes Cluster

If using kind:
```bash
cd setup
./scripts/setup-kind.sh
```

Or with the Makefile:
```bash
make setup-kind
```

### Step 2: Install Tekton

```bash
# Install Tekton Pipelines
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Install Tekton Triggers
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

# Wait for components to be ready
kubectl wait --for=condition=Ready pods --all -n tekton-pipelines --timeout=300s
kubectl wait --for=condition=Ready pods --all -n tekton-pipelines-resolvers --timeout=300s
```

Or use the legacy setup script:
```bash
cd setup
./scripts/setup-tekton.sh
```

### Step 3: Install CTF Challenge Resources

```bash
# Create namespace (if not using default)
kubectl create namespace ctf-challenges

# Install EventListener with vulnerable configuration
kubectl apply -f tekton/triggers/vulnerable-eventlistener.yaml

# Install Tasks
kubectl apply -f tekton/tasks/supporting-tasks.yaml
kubectl apply -f tekton/tasks/vulnerable-quality-check-task.yaml

# Install Pipeline
kubectl apply -f tekton/pipelines/vulnerable-pr-quality-pipeline.yaml
```

### Step 4: Create Flag Secret

```bash
# Create the flag that participants will try to steal
kubectl create secret generic ctf-flag \
  --from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
  -n default

# Verify secret was created
kubectl get secret ctf-flag -n default
```

**Important:** Change the flag value to something unique for your CTF!

### Step 5: Create Victim Repository

Create a Git repository with the victim code:

```bash
# Create repo directory
mkdir -p victim-repo
cd victim-repo

# Copy sample victim files
cp -r ../tekton/challenges/victim-repo-sample/* .

# Initialize git repo
git init
git add .
git commit -m "Initial commit"

# Push to your Git server (Gitea, GitHub, GitLab, etc.)
git remote add origin <your-git-server-url>
git push -u origin main
```

### Step 6: Configure Webhook (Optional)

For automatic triggering via webhooks:

```bash
# Expose EventListener service
kubectl port-forward svc/el-pr-quality-check-listener 8080:8080 -n default

# Or create an Ingress
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tekton-eventlistener
  namespace: default
spec:
  rules:
    - host: tekton-listener.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: el-pr-quality-check-listener
                port:
                  number: 8080
EOF
```

Then configure webhook in your Git server:
- **URL:** `http://tekton-listener.example.com/`
- **Secret:** Value from `github-webhook-secret`
- **Events:** Pull requests

### Step 7: Manual Testing (Without Webhook)

For CTF testing without webhooks:

```bash
# Create a test PipelineRun manually
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  generateName: test-pr-
  namespace: default
spec:
  pipelineRef:
    name: pr-quality-check-pipeline
  params:
    - name: pr-repo-url
      value: https://github.com/your-victim-repo.git
    - name: pr-sha
      value: main
    - name: pr-number
      value: "999"
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
EOF

# Watch the pipeline run
tkn pipelinerun logs --last -f
```

## Verification

### Verify All Resources

```bash
# Check EventListener
kubectl get eventlistener -n default

# Check Triggers
kubectl get triggerbinding,triggertemplate -n default

# Check Pipeline
kubectl get pipeline pr-quality-check-pipeline -n default

# Check Tasks
kubectl get task -n default

# Check ServiceAccounts
kubectl get sa tekton-triggers-sa,pipeline-sa -n default

# Check Secret
kubectl get secret ctf-flag -n default
```

### Test Pipeline Execution

```bash
# Start a test run
tkn pipeline start pr-quality-check-pipeline \
  --param pr-repo-url=https://github.com/victim/repo.git \
  --param pr-sha=main \
  --param pr-number=1 \
  --workspace name=source,emptyDir="" \
  --showlog

# Should see output like:
# PipelineRun started: pr-quality-check-pipeline-run-xxxxx
# ... logs showing clone, quality checks, results ...
```

## Participant Instructions

Provide participants with:

1. **Victim Repository URL**: The Git repo with benign quality checks
2. **Challenge Description**: See `tekton/challenges/CTF-CHALLENGE-GUIDE.md`
3. **Access to Cluster**: kubectl config or dashboard access (read-only except for their namespace)
4. **Goal**: Retrieve the flag from the `ctf-flag` secret

Participants should:
1. Fork the victim repository
2. Add malicious payload to `scripts/quality-check/main.go`
3. Submit PR or manually trigger pipeline
4. Exfiltrate the flag

## Advanced Setup Options

### Option 1: Isolated Namespaces per Team

```bash
# Create namespace per team
kubectl create namespace team-1
kubectl create namespace team-2

# Deploy challenge resources in each namespace
for ns in team-1 team-2; do
  kubectl apply -f tekton/triggers/vulnerable-eventlistener.yaml -n $ns
  kubectl apply -f tekton/tasks/ -n $ns
  kubectl apply -f tekton/pipelines/ -n $ns
  kubectl create secret generic ctf-flag \
    --from-literal=flag='FLAG{unique-flag-for-'$ns'}' \
    -n $ns
done
```

### Option 2: Different Difficulty Levels

**Easy Mode:**
- Flag in environment variable
- No network restrictions
- Direct log output allowed

**Medium Mode:**
- Flag in Kubernetes secret
- ServiceAccount has secret read permissions
- Must use Kubernetes API

**Hard Mode:**
- Flag in different namespace
- Must escalate privileges (RBAC misconfiguration)
- Network policy blocks direct egress
- Must use side channels or existing services

### Option 3: Add Monitoring/Detection

```bash
# Install Falco for runtime security monitoring
kubectl apply -f https://raw.githubusercontent.com/falcosecurity/falco/master/deploy/kubernetes/falco-daemonset-configmap.yaml

# Configure alerts for:
# - Unexpected API calls
# - Secret access
# - Network connections
# - Process spawning
```

## Troubleshooting

### Pipeline Not Starting

```bash
# Check EventListener logs
kubectl logs -l eventlistener=pr-quality-check-listener -n default

# Check webhook secret
kubectl get secret github-webhook-secret -n default -o yaml

# Verify ServiceAccount permissions
kubectl auth can-i create pipelineruns --as=system:serviceaccount:default:tekton-triggers-sa -n default
```

### Tasks Failing

```bash
# View TaskRun logs
tkn taskrun logs <taskrun-name> -f

# Check workspace PVC
kubectl get pvc -n default

# Verify images are pullable
kubectl run test --image=golang:1.21 --rm -it -- /bin/bash
```

### Permission Errors

```bash
# Check RBAC
kubectl get role,rolebinding -n default
kubectl describe role tekton-triggers-role -n default
kubectl describe role pipeline-role -n default

# Test ServiceAccount permissions
kubectl auth can-i --list --as=system:serviceaccount:default:pipeline-sa -n default
```

### Flag Not Accessible

```bash
# Verify secret exists
kubectl get secret ctf-flag -n default

# Check secret contents
kubectl get secret ctf-flag -n default -o jsonpath='{.data.flag}' | base64 -d

# Test access from pod
kubectl run test --image=alpine --rm -it -- sh
# Then from inside pod:
# TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
# curl -H "Authorization: Bearer $TOKEN" \
#      https://kubernetes.default.svc/api/v1/namespaces/default/secrets/ctf-flag \
#      --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

## Cleanup

```bash
# Delete all CTF resources
kubectl delete -f tekton/pipelines/
kubectl delete -f tekton/tasks/
kubectl delete -f tekton/triggers/
kubectl delete secret ctf-flag -n default

# Or delete entire namespace
kubectl delete namespace ctf-challenges

# Or delete entire cluster (if using kind)
make clean
```

## Security Notes

**For CTF Organizers:**

1. **Isolate the Challenge**: Run in isolated cluster or namespace
2. **Network Segmentation**: Use NetworkPolicies to prevent unintended access
3. **Resource Limits**: Set resource quotas to prevent DoS
4. **Audit Logging**: Enable to detect solutions and cheating
5. **Reset Between Teams**: Clean secrets and logs between teams
6. **Monitor Exfiltration**: Log all egress traffic to detect solutions

**Do NOT:**
- Run this on production clusters
- Give participants cluster-admin access
- Use real secrets or credentials
- Connect to internet without egress filtering

## CTF Variations

1. **Capture Multiple Flags**: Place flags in different locations
2. **Time-based Scoring**: Award more points for faster completion
3. **Multi-stage**: Token theft → privilege escalation → persistence
4. **Defense Challenge**: Fix the vulnerability instead of exploiting
5. **Blue Team Mode**: Detect and respond to the attack

## Resources

- Challenge Guide: `tekton/challenges/CTF-CHALLENGE-GUIDE.md`
- Malicious Payload Example: `tekton/challenges/malicious-payload-example.go`
- Attack Analysis: `ATTACK-ANALYSIS.md`
- Victim Repo Sample: `tekton/challenges/victim-repo-sample/`

## Support

For questions or issues:
1. Check logs: `kubectl logs` and `tkn logs`
2. Review resources: `kubectl get all -n default`
3. Test manually: Use `tkn pipeline start` for debugging
4. Check RBAC: `kubectl auth can-i`

Happy hacking! 🏴‍☠️
