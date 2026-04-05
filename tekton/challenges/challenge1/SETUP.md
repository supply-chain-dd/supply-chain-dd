# Challenge 1: Tekton Token Theft - Setup Guide

This guide walks you through setting up the victim repository and webhook configuration for the Tekton PWN Request CTF challenge.

## Prerequisites

Before proceeding, ensure you have completed the main environment setup:

```bash
make setup                    # Setup cluster, Gitea, Tekton, and registry
make configure-registry-tls   # Configure registry TLS trust
make setup-ctf-challenge      # Deploy CTF challenge resources
```

The `make setup-ctf-challenge` command has already:
- ✓ Deployed vulnerable Tekton resources (EventListener, Pipeline, Tasks)
- ✓ Created the CTF flag secret with registry credentials
- ✓ Prepared the victim repository at `/tmp/gitea/victim-repo`
- ✓ Configured Git credentials for Gitea access

## Step 1: Create Victim Repository in Gitea

### 1.1 Access Gitea Web UI

Open your browser and navigate to:
```
http://localhost:30002
```

Login with:
- **Username**: `ctf-admin`
- **Password**: `CTFSecurePass123!`

### 1.2 Create New Repository

1. Click the **"+"** icon in the top-right corner
2. Select **"New Repository"**
3. Fill in the repository details:
   - **Owner**: `ctf-admin` (should be pre-selected)
   - **Repository Name**: `victim-repo`
   - **Visibility**: Select **Private** (or Public, your choice)
   - **Initialize Repository**: **DO NOT** check "Initialize repository" options
   - **Add .gitignore**: None
   - **Add README**: None
   - **Add License**: None
4. Click **"Create Repository"**

You should now see an empty repository with setup instructions.

### 1.3 Push Victim Repository Code

The victim repository has already been prepared at `/tmp/gitea/victim-repo` with the complete Git history restored.

Open a terminal and run:

```bash
cd /tmp/gitea/victim-repo

# Add the Gitea remote
git remote add origin http://localhost:30002/ctf-admin/victim-repo.git

# Push to Gitea (with credentials configured via environment)
GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git push -u origin main
```

**Important**: The `GIT_CONFIG_GLOBAL` environment variable tells git to use the credential helper we configured, and `GIT_TERMINAL_PROMPT=0` prevents git from hanging if credentials are missing.

**Expected output:**
```
remote: . Processing 1 references
remote: Processed 1 references in total
To http://localhost:30002/ctf-admin/victim-repo.git
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

### 1.4 Verify Repository

Refresh the Gitea web UI (http://localhost:30002/ctf-admin/victim-repo). You should now see:
- ✓ Source code files (`main.go`, `Dockerfile`, etc.)
- ✓ Complete Git history with multiple commits
- ✓ `.tekton/` directory with Tekton pipeline configuration

You can also verify Git connectivity:

```bash
cd /tmp/gitea/victim-repo

# Fetch to verify connectivity (use the same environment variables)
GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git fetch origin

# Should show no errors
```

## Step 2: Configure Webhook

To trigger the vulnerable Tekton pipeline automatically when pull requests are created, configure a webhook in Gitea.

### 2.1 Get EventListener Service URL

First, find the EventListener service URL. Run:

```bash
kubectl get svc -n ctf-challenge el-pr-quality-check-listener
```

**Expected output:**
```
NAME                           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
el-pr-quality-check-listener   ClusterIP   10.96.X.X       <none>        8080/TCP   Xm
```

The EventListener is running inside the cluster. Since Gitea is also running in the cluster, it can access it via:
```
http://el-pr-quality-check-listener.ctf-challenge.svc.cluster.local:8080
```

### 2.2 Add Webhook in Gitea

1. In the Gitea web UI, navigate to your `victim-repo` repository
2. Click **"Settings"** (top-right, gear icon)
3. In the left sidebar, click **"Webhooks"**
4. Click **"Add Webhook"** → Select **"Gitea"** (or **"Gogs"** if Gitea not available)
5. Fill in the webhook configuration:

   **Webhook Configuration:**
   - **Target URL**: 
     ```
     http://el-pr-quality-check-listener.ctf-challenge.svc.cluster.local:8080
     ```
   - **HTTP Method**: `POST`
   - **POST Content Type**: `application/json`
   - **Secret**: 
     ```
     change-me-in-production
     ```
   - **Trigger On**: Select **"Custom Events..."**
     - Check ☑ **Pull Request**
     - Uncheck all other events
   - **Active**: Check ☑ **Active**

6. Click **"Add Webhook"**

### 2.3 Test Webhook (Optional)

You can test the webhook delivery:

1. In the webhook settings, scroll down to **"Recent Deliveries"**
2. Click **"Test Delivery"**
3. Check the response:
   - **Status**: Should be `200 OK` or `201 Created`
   - **Response Body**: Should indicate successful webhook processing

If you see errors, verify:
- The EventListener service is running: `kubectl get pods -n ctf-challenge`
- The service URL is correct (check for typos)
- The secret matches: `change-me-in-production`

**Note**: You cannot test the Pull Request webhook without an actual pull request. Testing with "Push" events won't trigger the pipeline because the EventListener only accepts `pull_request` events.

## Step 3: Test the Webhook (Create a Pull Request)

To verify the webhook works end-to-end, create a test pull request:

### 3.1 Create a Test Branch and Push

```bash
cd /tmp/gitea/victim-repo

# Create a new branch
git checkout -b test-webhook

# Make a small change (optional)
echo "# Test" >> README.md
git add README.md
git commit -m "Test webhook trigger"

# Push the branch
GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git push --set-upstream origin test-webhook
```

### 3.2 Create Pull Request in Gitea

After pushing, Gitea will show a helpful message:
```
remote: Create a new pull request for 'test-webhook':        
remote:   http://gitea-http.gitea.svc.cluster.local:3000/ctf-admin/victim-repo/pulls/new/test-webhook
```

**Create the PR via web UI**:

1. Go to http://localhost:30002/ctf-admin/victim-repo
2. You should see a banner: **"test-webhook had recent pushes"** with a **"Compare & pull request"** button
3. Click **"Compare & pull request"**
4. Fill in:
   - **Title**: "Test webhook"
   - **Description**: "Testing Tekton webhook integration"
5. Click **"Create Pull Request"**

**Or use the direct URL**:
- http://localhost:30002/ctf-admin/victim-repo/compare/main...test-webhook

### 3.3 Verify Pipeline Started

Once you create the PR, the webhook should trigger immediately. Check if a PipelineRun was created:

```bash
# Watch for new PipelineRuns
kubectl get pipelinerun -n ctf-challenge --watch

# Or check the latest PipelineRun
kubectl get pipelinerun -n ctf-challenge --sort-by=.metadata.creationTimestamp | tail -5

# View PipelineRun logs (if you have tkn CLI)
tkn pipelinerun logs -n ctf-challenge --last -f
```

You should see a PipelineRun with a name like `pr-quality-check-xxxxx` that was automatically created by the webhook.

## Step 4: Verify Complete Setup

### 4.1 Check All Resources

Run the verification command:

```bash
make verify-ctf
```

**Expected output:**
```
Verifying Tekton CTF Challenge...

Tekton Pipelines:
  (list of Tekton pods)

CTF Pipeline:
NAME                         AGE
pr-quality-check-pipeline    Xm

CTF Tasks:
  (list of tasks)

EventListener:
NAME                        ADDRESS                                               AVAILABLE   REASON
pr-quality-check-listener   http://el-pr-quality-check-listener.ctf-challenge... True        MinimumReplicasAvailable

CTF Flag Secret:
  ✓ Flag secret exists

✓ Verification complete
```

### 4.2 Check Victim Repository

Verify the victim repository is accessible:

```bash
# Check repository in web UI
# Visit: http://localhost:30002/ctf-admin/victim-repo

# Or test git connectivity
cd /tmp/gitea/victim-repo
GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git fetch origin
```

### 4.3 Check Webhook Deliveries

In Gitea, verify webhook deliveries are successful:

1. Go to: http://localhost:30002/ctf-admin/victim-repo/settings/hooks/1
2. Scroll down to **"Recent Deliveries"**
3. You should see successful deliveries (green checkmarks) for your Pull Request events
4. Click on a delivery to see the request/response details

## Step 5: Understanding the Attack Surface

Now that everything is set up, here's what participants will exploit:

### Vulnerability Overview

The Tekton pipeline is configured with the **"Pwn Request"** vulnerability:

1. **Vulnerable TriggerBinding** ([vulnerable-eventlistener.yaml:38-39](../../../triggers/vulnerable-eventlistener.yaml#L38-L39)):
   ```yaml
   - name: pr-repo-url
     value: $(body.pull_request.head.repo.clone_url)  # Attacker's fork!
   - name: pr-sha
     value: $(body.pull_request.head.sha)             # Attacker's code!
   ```

2. **Overprivileged ServiceAccount** ([vulnerable-eventlistener.yaml:164-189](../../../triggers/vulnerable-eventlistener.yaml#L164-L189)):
   - The `default` ServiceAccount (used by TaskRuns) has `get` and `list` permissions on **all secrets**
   - This allows malicious code to read the `ctf-flag` secret

3. **No Code Isolation**:
   - Attacker's code runs in the same namespace as the flag secret
   - No network policies or security contexts restrict access

### Attack Flow

```
1. Attacker forks victim-repo
2. Attacker modifies scripts/quality-check/main.go with malicious payload
3. Attacker creates Pull Request
4. Gitea webhook triggers EventListener
5. EventListener creates PipelineRun with attacker's code (pr-repo-url, pr-sha)
6. Pipeline clones attacker's fork
7. Pipeline runs attacker's malicious quality-check script
8. Malicious script uses ServiceAccount token to read ctf-flag secret
9. Flag exfiltrated!
```

## Next Steps

Participants should now:

1. **Review the challenge guide**: [CTF-CHALLENGE-GUIDE.md](CTF-CHALLENGE-GUIDE.md)
2. **Understand the vulnerability**: [ATTACK-ANALYSIS.md](ATTACK-ANALYSIS.md)
3. **Test the attack**: Fork the repo, modify the code, create a PR
4. **Capture the flag**: Extract the flag from the secret

## Troubleshooting

### Webhook not triggering

```bash
# Check EventListener logs
kubectl logs -l eventlistener=pr-quality-check-listener -n ctf-challenge -f

# Check EventListener service
kubectl get svc -n ctf-challenge el-pr-quality-check-listener

# Test webhook delivery from Gitea UI (Settings → Webhooks → Test Delivery)
```

### Pipeline not starting

```bash
# Check PipelineRuns
kubectl get pipelinerun -n ctf-challenge

# Check TriggerBinding and TriggerTemplate
kubectl get triggerbinding,triggertemplate -n ctf-challenge

# Check ServiceAccount permissions
kubectl auth can-i create pipelineruns --as=system:serviceaccount:ctf-challenge:tekton-triggers-sa -n ctf-challenge
```

### Repository push fails or hangs

If `git push` hangs or fails with "could not read Username", it means git isn't using the credential helper:

```bash
# Verify Git credentials exist
cat /tmp/gitea/.git-credentials

# Verify Gitea is accessible
curl http://localhost:30002

# Always use the environment variables when running git commands
cd /tmp/gitea/victim-repo
GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git push -u origin main

# Or create an alias for convenience
alias git-ctf='GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git'
git-ctf push -u origin main

# Check Gitea repository exists in web UI
# Visit http://localhost:30002/ctf-admin/victim-repo
```

### Flag secret not found

```bash
# Verify secret exists
kubectl get secret ctf-flag -n ctf-challenge

# Check secret contents (base64 encoded)
kubectl get secret ctf-flag -n ctf-challenge -o yaml

# Verify ServiceAccount has permissions
kubectl auth can-i get secrets --as=system:serviceaccount:ctf-challenge:default -n ctf-challenge
```

## Security Notes

**For CTF Organizers:**

This is a **deliberately vulnerable** configuration for educational purposes:
- ✗ Default ServiceAccount has excessive permissions
- ✗ Untrusted code runs in the same namespace as secrets
- ✗ No network policies restrict egress
- ✗ No security contexts or admission policies

**Do NOT use this in production!**

To see the **secure** version, check:
- [tekton-patched/](security/../tekton-patched/) - Hardened configuration
- [security/](security/) - Prevention and detection mechanisms

## Additional Resources

- [CTF Challenge Guide](CTF-CHALLENGE-GUIDE.md) - Participant walkthrough
- [Attack Analysis](ATTACK-ANALYSIS.md) - Technical deep-dive comparing vulnerable vs. secure
- [Security Architecture](security/ARCHITECTURE.md) - Prevention and detection layers
- [Victim Repository Sample](../victim-repo-sample/) - Source code with attack vectors

Happy hacking! 🏴‍☠️
