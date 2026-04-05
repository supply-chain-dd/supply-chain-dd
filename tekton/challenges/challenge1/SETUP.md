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

# Configure Git to use the credentials file
export GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig

# Add the Gitea remote
git remote add origin http://localhost:30002/ctf-admin/victim-repo.git

# Push to Gitea
git push -u origin main
```

**Expected output:**
```
Enumerating objects: X, done.
Counting objects: 100% (X/X), done.
...
To http://localhost:30002/ctf-admin/victim-repo.git
 * [new branch]      main -> main
Branch 'main' set up to track remote branch 'main' from 'origin'.
```

### 1.4 Verify Repository

Refresh the Gitea web UI. You should now see:
- ✓ Source code files (`main.go`, `Dockerfile`, etc.)
- ✓ Complete Git history with multiple commits
- ✓ `.tekton/` directory with Tekton pipeline configuration

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

## Step 3: Verify Setup

### 3.1 Check All Resources

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

### 3.2 Check Victim Repository

Verify the victim repository exists in Gitea:

```bash
# From /tmp/gitea/victim-repo
cd /tmp/gitea/victim-repo
export GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig

# Fetch to verify connectivity
git fetch origin

# Should show no errors
```

## Step 4: Understanding the Attack Surface

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

### Repository push fails

```bash
# Verify Git credentials
cat /tmp/gitea/.git-credentials

# Verify Gitea is accessible
curl http://localhost:30002

# Re-export Git config
export GIT_CONFIG_GLOBAL=/tmp/gitea/.gitconfig

# Check Gitea repository exists
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
