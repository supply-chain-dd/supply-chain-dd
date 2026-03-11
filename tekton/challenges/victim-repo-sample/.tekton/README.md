# Tekton CI/CD Configuration

This document describes our Tekton Pipelines setup for automated PR quality checks.

## Architecture

```
GitHub PR Event
      ↓
EventListener (Webhook)
      ↓
TriggerBinding (Extract PR data)
      ↓
TriggerTemplate (Create PipelineRun)
      ↓
Pipeline (pr-quality-check-pipeline)
      ↓
Tasks:
  1. clone-pr-code
  2. show-repo-info
  3. run-quality-checks
  4. post-results
```

## EventListener

Endpoint: `http://tekton-listener.example.com/`

Listens for GitHub webhook events:
- `pull_request` (opened, synchronize, reopened)

## Pipeline: pr-quality-check-pipeline

**Triggered on:** Pull request events

**Steps:**
1. **clone-pr-code**: Clones the PR code from the fork
2. **show-repo-info**: Displays PR information
3. **run-quality-checks**: Executes `scripts/quality-check/main.go`
4. **post-results**: Reports results

**ServiceAccount:** `pipeline-sa`
**Permissions:** Read-only access to repository, write access to PR comments

## Running Locally

You can test the pipeline locally using `tkn`:

```bash
# Create a test PipelineRun
tkn pipeline start pr-quality-check-pipeline \
  --param pr-repo-url=https://github.com/awesome-project/awesome-project.git \
  --param pr-sha=main \
  --param pr-number=123 \
  --workspace name=source,emptyDir="" \
  --showlog
```

## Security Considerations

- The pipeline runs with limited permissions
- Only reads from the repository
- Cannot modify repository settings
- Runs in isolated Kubernetes namespace

## Troubleshooting

### Pipeline fails immediately
- Check EventListener logs: `kubectl logs -n default -l eventlistener=pr-quality-check-listener`

### Quality checks fail
- View PipelineRun logs: `tkn pipelinerun logs <run-name>`
- Check quality script: `scripts/quality-check/main.go`

### Webhook not triggering
- Verify webhook URL in GitHub settings
- Check EventListener is running: `kubectl get eventlistener`

## Maintenance

**Pipeline Updates:**
1. Edit pipeline definition in cluster
2. Test with sample PR
3. Document changes here

**Adding New Checks:**
1. Modify `scripts/quality-check/main.go`
2. Test locally: `cd scripts/quality-check && go run .`
3. Submit PR (will trigger existing checks)
4. Merge after review

## Contact

For CI/CD questions, contact the DevOps team.
