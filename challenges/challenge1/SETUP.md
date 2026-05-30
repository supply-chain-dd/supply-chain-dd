# Challenge 1: Tekton Token Theft - Setup Guide

This guide walks you through setting up the victim repository and webhook configuration for the Tekton PWN Request deep dive challenge.

## Prerequisites

Before proceeding, ensure you have completed the main environment setup:

```bash
make setup                    # Setup cluster, Gitea, Tekton, and registry
make configure-registry-tls   # Configure registry TLS trust
make setup-ci-pr-pipeline      # Deploy deep dive challenge resources
```

The `make setup-ci-pr-pipeline` command has already:
- ✓ Deployed vulnerable Tekton resources (EventListener, Pipeline, Tasks)
- ✓ Created the registry credentials secret with registry credentials
- ✓ Prepared the victim repository at `/tmp/gitea/recipe-api`
- ✓ Configured Git credentials for Gitea access
- ✓ Created the recipe-api repository on the Gitea instance

## Step 1: Verify Victim Repository in Gitea

### 1.1 Access Gitea Web UI

Open your browser and navigate to:
```
http://gitea.sc.local:30080
```

Login with:
- **Username**: `sc-admin`
- **Password**: `SecurePass123!`



### 1.2 Verify Repository

Refresh the Gitea web UI (http://gitea.sc.local:30080/sc-admin/recipe-api). You should now see:
- ✓ Source code files (`main.go`, `Dockerfile`, etc.)
- ✓ Complete Git history with multiple commits
- ✓ `.tekton/` directory with Tekton pipeline configuration


## Step 2: Configure Webhook

To trigger the vulnerable Tekton pipeline automatically when pull requests are created, configure a webhook in Gitea.

### 2.1 Get EventListener Service URL

First, find the EventListener service URL. Run:

```bash
kubectl get svc -n ci el-pr-quality-check-listener
```

**Expected output:**
```
NAME                           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
el-pr-quality-check-listener   ClusterIP   10.96.X.X       <none>        8080/TCP   Xm
```

The EventListener is running inside the cluster. Since Gitea is also running in the cluster, it can access it via:
```
http://el-pr-quality-check-listener.ci.svc.cluster.local:8080
```

### 2.2 Add Webhook in Gitea

1. In the Gitea web UI, navigate to your `recipe-api` repository
2. Click **"Settings"** (top-right, gear icon)
3. In the left sidebar, click **"Webhooks"**
4. Click **"Add Webhook"** → Select **"Gitea"** (or **"Gogs"** if Gitea not available)
5. Fill in the webhook configuration:

   **Webhook Configuration:**
   - **Target URL**: 
     ```
     http://el-pr-quality-check-listener.ci.svc.cluster.local:8080
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

**Note**: You cannot test the Pull Request webhook without an actual pull request. Testing with "Push" events won't trigger the pipeline because the EventListener only accepts `pull_request` events.

## Step 3: Test the Webhook (Create a Pull Request)

To verify the webhook works end-to-end, create a test pull request:

### 3.0 Clone (or fork) the repository
```
rm -rf /tmp/gitea/recipe-api
mkdir -p /tmp/gitea
cd /tmp/gitea
git clone http://sc-admin:SecurePass123\!@gitea.sc.local:30080/sc-admin/recipe-api
echo "Creating Git credentials for Gitea access..."
echo "[user]" > /tmp/gitea/.gitconfig
echo "	name = SC Admin" >> /tmp/gitea/.gitconfig
echo "	email = sc-admin@localhost" >> /tmp/gitea/.gitconfig
echo "[credential]" >> /tmp/gitea/.gitconfig
echo "	helper = store --file /tmp/gitea/.git-credentials" >> /tmp/gitea/.gitconfig
echo "http://sc-admin:SecurePass123\!@gitea.sc.local:30080" > /tmp/gitea/.git-credentials
chmod 600 /tmp/gitea/.git-credentials
```
### 3.1 Create a Test Branch and Push

```bash
cd /tmp/gitea/recipe-api

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
remote:   http://gitea.sc.local:30080/sc-admin/recipe-api/pulls/new/test-webhook
```

**Create the PR via web UI**:

1. Go to http://gitea.sc.local:30080/sc-admin/recipe-api
2. You should see a banner: **"test-webhook had recent pushes"** with a **"Compare & pull request"** button
3. Click **"Compare & pull request"**
4. Fill in:
   - **Title**: "Test webhook"
   - **Description**: "Testing Tekton webhook integration"
5. Click **"Create Pull Request"**

**Or use the direct URL**:
- http://gitea.sc.local:30080/sc-admin/recipe-api/compare/main...test-webhook

### 3.3 Verify Pipeline Started

Once you create the PR, the webhook should trigger immediately. Check if a PipelineRun was created:

```bash
# Watch for new PipelineRuns
kubectl get pipelinerun -n ci --watch

# Or check the latest PipelineRun
kubectl get pipelinerun -n ci --sort-by=.metadata.creationTimestamp | tail -5

# View PipelineRun logs (if you have tkn CLI)
tkn pipelinerun logs -n ci --last -f
```

You should see a PipelineRun with a name like `pr-quality-check-xxxxx` that was automatically created by the webhook.

## Step 4: Verify Complete Setup

### 4.1 Check All Resources

Run the verification command:

```bash
make verify-ci-pr-pipeline
```

**Expected output:**
```
Verifying Tekton Deep Dive Challenge...

Tekton Pipelines:
  (list of Tekton pods)

CI Pipeline:
NAME                         AGE
pr-quality-check-pipeline    Xm

CI Tasks:
  (list of tasks)

EventListener:
NAME                        ADDRESS                                               AVAILABLE   REASON
pr-quality-check-listener   http://el-pr-quality-check-listener.ci... True        MinimumReplicasAvailable

Registry Credentials Secret:
  ✓ Flag secret exists

✓ Verification complete
```

### 4.2 Check Victim Repository

Verify the victim repository is accessible:

```bash
# Check repository in web UI
# Visit: http://gitea.sc.local:30080/sc-admin/recipe-api

# Or test git connectivity
cd /tmp/gitea/recipe-api
GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git fetch origin
```

### 4.3 Check Webhook Deliveries

In Gitea, verify webhook deliveries are successful:

1. Go to: http://gitea.sc.local:30080/sc-admin/recipe-api/settings/hooks/1
2. Scroll down to **"Recent Deliveries"**
3. You should see successful deliveries (green checkmarks) for your Pull Request events
4. Click on a delivery to see the request/response details

## Step 5: Understanding the Attack Surface

Now that everything is set up, here's what participants will exploit:

### Vulnerability Overview

The Tekton pipeline is configured with the **"Pwn Request"** vulnerability:

1. **Vulnerable TriggerBinding** ([vulnerable-eventlistener.yaml:38-39](tekton/triggers/vulnerable-eventlistener.yaml#L38-L39)):
   ```yaml
   - name: pr-repo-url
     value: $(body.pull_request.head.repo.clone_url)  # Attacker's fork!
   - name: pr-sha
     value: $(body.pull_request.head.sha)             # Attacker's code!
   ```

2. **Overprivileged ServiceAccount** ([vulnerable-eventlistener.yaml:164-189](tekton/triggers/vulnerable-eventlistener.yaml#L164-L189)):
   - The `default` ServiceAccount (used by TaskRuns) has `get` and `list` permissions on **all secrets**
   - This allows malicious code to read the `registry-credentials` secret

3. **No Code Isolation**:
   - Attacker's code runs in the same namespace as the flag secret
   - No network policies or security contexts restrict access

### Attack Flow

```
1. Attacker forks recipe-api
2. Attacker modifies scripts/quality-check/main.go with malicious payload
3. Attacker creates Pull Request
4. Gitea webhook triggers EventListener
5. EventListener creates PipelineRun with attacker's code (pr-repo-url, pr-sha)
6. Pipeline clones attacker's fork
7. Pipeline runs attacker's malicious quality-check script
8. Malicious script uses ServiceAccount token to read registry-credentials secret
9. Flag exfiltrated!
```

## Next Steps

Participants should now:

1. **Review the challenge guide**: [ATTACK-GUIDE.md](ATTACK-GUIDE.md)
2. **Understand the vulnerability**: [ATTACK-ANALYSIS.md](ATTACK-ANALYSIS.md)
3. **Test the attack**: Fork the repo, modify the code, create a PR
4. **Capture the flag**: Extract the flag from the secret

## Troubleshooting

### Webhook not triggering

```bash
# Check EventListener logs
kubectl logs -l eventlistener=pr-quality-check-listener -n ci -f

# Check EventListener service
kubectl get svc -n ci el-pr-quality-check-listener

# Test webhook delivery from Gitea UI (Settings → Webhooks → Test Delivery)
```

### Pipeline not starting

```bash
# Check PipelineRuns
kubectl get pipelinerun -n ci

# Check TriggerBinding and TriggerTemplate
kubectl get triggerbinding,triggertemplate -n ci

# Check ServiceAccount permissions
kubectl auth can-i create pipelineruns --as=system:serviceaccount:ci:tekton-triggers-sa -n ci
```

### Repository push fails or hangs

If `git push` hangs or fails with "could not read Username", it means git isn't using the credential helper:

```bash
# Verify Git credentials exist
cat /tmp/gitea/.git-credentials

# Verify Gitea is accessible
curl http://gitea.sc.local:30080

# Always use the environment variables when running git commands
cd /tmp/gitea/recipe-api
GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git push -u origin main

# Or create an alias for convenience
alias git-sc='GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig GIT_TERMINAL_PROMPT=0 git'
git-sc push -u origin main

# Check Gitea repository exists in web UI
# Visit http://gitea.sc.local:30080/sc-admin/recipe-api
```

### Flag secret not found

```bash
# Verify secret exists
kubectl get secret registry-credentials -n ci

# Check secret contents (base64 encoded)
kubectl get secret registry-credentials -n ci -o yaml

# Verify ServiceAccount has permissions
kubectl auth can-i get secrets --as=system:serviceaccount:ci:default -n ci
```

## Security Notes

**For Organizers:**

This is a **deliberately vulnerable** configuration for educational purposes:
- ✗ Default ServiceAccount has excessive permissions
- ✗ Untrusted code runs in the same namespace as secrets
- ✗ No network policies restrict egress
- ✗ No security contexts or admission policies

**Do NOT use this in production!**

To see the **secure** version, check:
- [tekton-patched/](tekton-patched/) - Hardened configuration
- [security/](security/) - Prevention and detection mechanisms

## Additional Resources

- [Deep Dive Challenge Guide](ATTACK-GUIDE.md) - Participant walkthrough
- [Attack Analysis](ATTACK-ANALYSIS.md) - Technical deep-dive comparing vulnerable vs. secure
- [Security Architecture](security/ARCHITECTURE.md) - Prevention and detection layers
- [Victim Repository Sample](../recipe-api-sample/) - Source code with attack vectors

Happy hacking! 🏴‍☠️
