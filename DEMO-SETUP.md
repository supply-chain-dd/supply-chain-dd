# Deep Dive Demo Setup Guide

This guide provides a fully automated setup for challenges 1 and 2, minimizing manual intervention for deep dive sessions.

## Quick Start (Fully Automated)

Run the complete automated setup with a single command:

```bash
make setup-demo
```

This will:
1. ✅ Create KinD cluster
2. ✅ Install Gitea
3. ✅ Install Tekton Pipelines and Triggers
4. ✅ Setup local Docker registry with TLS
5. ✅ Configure registry TLS certificates
6. ✅ Seed recipe-api repository to Gitea
7. ✅ Install Challenge 1 Tekton resources (vulnerable PR pipeline)
8. ✅ Install Challenge 2 Tekton resources (push build pipeline)
9. ✅ Create Gitea webhooks automatically via API
10. ✅ Verify all prerequisites are met

## Step-by-Step Setup (Manual Control)

If you prefer to run each step separately:

```bash
# 1. Core infrastructure
make setup

# 2. Configure registry TLS trust (interactive)
make configure-registry-tls

# 3. Setup Challenge 1 (PR Quality Check Attack)
make setup-ctf-challenge

# 4. Setup Challenge 2 (Container Layer Leak Attack)
make setup-challenge2-tekton

# 5. Setup Gitea webhooks (automated)
make setup-gitea-webhooks

# 6. Verify everything is ready
make verify-demo-readiness
```

## What Gets Automated

### Challenge 1: Pull Request Target Attack
- ✅ Vulnerable PR quality check pipeline
- ✅ Git clone task
- ✅ Quality check task (vulnerable to secret theft)
- ✅ EventListener for pull_request events
- ✅ Gitea webhook configured automatically
- ✅ CTF flag secret with registry credentials

### Challenge 2: Container Layer Leak Attack
- ✅ Push build pipeline
- ✅ Go application build task
- ✅ Container image build task (Kaniko)
- ✅ Container image push task
- ✅ EventListener for push events
- ✅ Gitea webhook configured automatically
- ✅ ServiceAccounts and RBAC
- ✅ Registry authentication secrets

### Webhooks (Fully Automated)
The `setup-gitea-webhooks` script automatically creates webhooks via Gitea API:
- **PR Webhook**: Triggers Challenge 1 pipeline on pull_request events
- **Push Webhook**: Triggers Challenge 2 pipeline on push events

No manual webhook configuration in Gitea UI required!

## Access Information

After `make setup-demo` completes:

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| Gitea | http://localhost:30002 | ctf-admin | CTFSecurePass123! |
| Registry | https://localhost:30000 | ctf-admin | CTFRegistryPass123! |

## Verification

Check that everything is ready:

```bash
make verify-demo-readiness
```

This verifies:
- ✅ Cluster is running
- ✅ Gitea is accessible
- ✅ Registry is accessible
- ✅ Tekton is installed
- ✅ recipe-api repository exists
- ✅ All pipelines and tasks are deployed
- ✅ All EventListeners have services
- ✅ ServiceAccounts exist
- ✅ Webhooks are configured
- ✅ Secrets and ConfigMaps are created

## Starting the Deep Dive Session

Once setup is complete, you can start the demo immediately:

### Challenge 1: Pull Request Target Attack

1. Open Gitea: http://localhost:30002
2. Login as `ctf-admin` / `CTFSecurePass123!`
3. Go to `recipe-api` repository
4. Create a new branch and pull request with malicious code
5. Watch the pipeline run: `kubectl get pipelineruns -n ctf-challenge -w`
6. Follow the attack guide: [challenges/challenge1/CTF-CHALLENGE-GUIDE.md](challenges/challenge1/CTF-CHALLENGE-GUIDE.md)

### Challenge 2: Container Layer Leak Attack

1. Use registry credentials obtained from Challenge 1
2. Pull the recipe-api image from the registry
3. Extract git history from container layers
4. Find leaked secrets in git history
5. Follow the attack guide: [challenges/challenge2/CTF-CHALLENGE-GUIDE.md](challenges/challenge2/CTF-CHALLENGE-GUIDE.md)

## Useful Commands

```bash
# Monitor all pipeline runs
kubectl get pipelineruns -n ctf-challenge -w

# View pipeline run logs (requires tkn CLI)
kubectl tkn pipelinerun logs -f -n ctf-challenge

# List all webhooks
curl -s -u ctf-admin:CTFSecurePass123! \
  http://localhost:30002/api/v1/repos/ctf-admin/recipe-api/hooks | jq

# Check EventListener services
kubectl get svc -n ctf-challenge | grep el-

# Check registry images
curl --cacert certs/registry.crt -u ctf-admin:CTFRegistryPass123! \
  https://localhost:30000/v2/_catalog | jq
```

## Troubleshooting

### Registry TLS Issues

If you see TLS certificate errors:

```bash
make configure-registry-tls
```

This interactive script will help you trust the self-signed certificate.

### Webhooks Not Triggering

1. Verify webhooks exist:
   ```bash
   curl -s -u ctf-admin:CTFSecurePass123! \
     http://localhost:30002/api/v1/repos/ctf-admin/recipe-api/hooks | jq
   ```

2. Re-create webhooks:
   ```bash
   make setup-gitea-webhooks
   ```

3. Check EventListener pods:
   ```bash
   kubectl get pods -n ctf-challenge | grep el-
   ```

### Pipeline Not Starting

1. Check EventListener logs:
   ```bash
   kubectl logs -n ctf-challenge -l eventlistener=pr-quality-check-listener
   kubectl logs -n ctf-challenge -l eventlistener=push-build-listener
   ```

2. Verify webhook secret matches:
   ```bash
   kubectl get secret github-webhook-secret -n ctf-challenge -o yaml
   ```

## Cleanup

Reset the environment:

```bash
make clean
```

This deletes the KinD cluster and all resources.

## Time Estimates

| Operation | Duration |
|-----------|----------|
| Full automated setup (`make setup-demo`) | ~5-7 minutes |
| Verification (`make verify-demo-readiness`) | ~10 seconds |
| Creating a single pipeline run | ~2-3 minutes |
| Complete Challenge 1 attack | ~10-15 minutes |
| Complete Challenge 2 attack | ~15-20 minutes |

## What's NOT Automated

The following require manual steps:
- Creating pull requests in Gitea (Challenge 1 attack)
- Pushing commits to main branch (Challenge 2 attack)
- Executing the actual attack payloads
- Applying security remediations

This is intentional - the demo requires showing the manual attack steps!

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     KinD Cluster                            │
│                                                             │
│  ┌────────────┐      ┌──────────────┐     ┌─────────────┐   │
│  │   Gitea    │────▶│   Tekton     │───▶│  Registry   │   │
│  │  :30002    │      │  Pipelines   │     │   :30000    │   │
│  │            │      │              │     │  (TLS)      │   │
│  │  Webhooks: │      │  Challenge 1:│     │             │   │
│  │  • PR      │      │  PR Pipeline │     │  Images:    │   │
│  │  • Push    │      │              │     │  • recipe-  │   │
│  │            │      │  Challenge 2:│     │    api:v1.0 │   │
│  │  recipe-   │      │  Push Build  │     │             │   │
│  │  api repo  │      │              │     │             │   │
│  └────────────┘      └──────────────┘     └─────────────┘   │
│                                                             │
│  Namespace: ctf-challenge                                   │
│  • EventListeners (el-pr-quality-check-listener,            │
│                    el-push-build-listener)                  │
│  • ServiceAccounts (pr-pipeline-readonly,                   │
│                     tekton-triggers-sa)                     │
│  • Secrets (ctf-flag, registry-docker-config)               │
└─────────────────────────────────────────────────────────────┘
```

## Next Steps

After completing the automated setup:

1. ✅ Review [challenges/challenge1/ATTACK-ANALYSIS.md](challenges/challenge1/ATTACK-ANALYSIS.md)
2. ✅ Review [challenges/challenge2/ATTACK-ANALYSIS.md](challenges/challenge2/ATTACK-ANALYSIS.md)
3. ✅ Prepare demo materials
4. ✅ Test the attacks once
5. ✅ Ready for deep dive session!
