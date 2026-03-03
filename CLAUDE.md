# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Capture The Flag (CTF) environment setup project focused on supply chain security. The project provides automated scripts to provision a complete Kubernetes environment for CTF participants, including:

- A KinD (Kubernetes in Docker) cluster
- Tekton Pipelines for CI/CD workflows
- Custom Tekton tasks and pipelines for CTF challenges

## Architecture

### Component Stack
1. **KinD Cluster**: Local Kubernetes cluster running in Docker containers
   - Configured with port mappings (30000, 30001) for service access
   - Custom containerd configuration for registry integration
   - Single control-plane node setup

2. **Tekton Pipelines**: Cloud-native CI/CD system
   - Tekton Pipelines: Core pipeline execution engine
   - Tekton Triggers: Event-driven pipeline automation
   - Custom tasks and pipelines stored in `tekton/` directory

### Directory Structure
```
├── scripts/               # Shell scripts for environment setup
│   ├── setup-kind.sh     # KinD cluster provisioning
│   ├── setup-tekton.sh   # Tekton installation
│   └── cleanup.sh        # Environment teardown
├── tekton/               # Tekton resource definitions
│   ├── tasks/            # Reusable Tekton Task definitions
│   └── pipelines/        # Tekton Pipeline definitions
├── k8s/                  # Kubernetes manifests
│   └── base/             # Base configurations
├── Makefile              # Primary automation interface
└── setup.sh              # Main orchestration script
```

## Development Commands

### Environment Setup
```bash
# Complete setup (creates cluster + installs Tekton)
make setup

# Individual components
make setup-kind      # Create KinD cluster only
make setup-tekton    # Install Tekton only

# Alternative: use main script
./setup.sh
```

### Verification and Status
```bash
make verify         # Verify environment is working
make status         # Show detailed status
```

### Cleanup
```bash
make clean          # Delete cluster and cleanup
./scripts/cleanup.sh  # Alternative cleanup method
```

### Configuration Variables
Environment variables that control setup:
- `CLUSTER_NAME` (default: `ctf-cluster`) - KinD cluster name
- `TEKTON_PIPELINE_VERSION` (default: `v0.53.0`) - Tekton Pipelines version
- `TEKTON_TRIGGERS_VERSION` (default: `v0.25.0`) - Tekton Triggers version
- `KIND_VERSION` (default: `v1.27.3`) - Kubernetes version for KinD

Example:
```bash
CLUSTER_NAME=my-ctf TEKTON_PIPELINE_VERSION=v0.50.0 make setup
```

## Adding CTF Challenges

### Tekton Tasks
Create new Tekton tasks in `tekton/tasks/`:
```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: example-task
spec:
  steps:
    - name: step-name
      image: alpine
      script: |
        #!/bin/sh
        # Task implementation
```

Tasks are automatically applied during `make setup-tekton` if files exist.

### Tekton Pipelines
Create pipelines in `tekton/pipelines/`:
```yaml
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: example-pipeline
spec:
  tasks:
    - name: task-ref
      taskRef:
        name: example-task
```

Pipelines are automatically applied during `make setup-tekton` if files exist.

## Script Architecture

### setup-kind.sh
- Validates KinD is installed
- Checks for existing cluster to prevent conflicts
- Creates cluster with custom config (port mappings, registry config)
- Waits for cluster readiness using `kubectl wait`

### setup-tekton.sh
- Installs Tekton Pipelines from official releases
- Installs Tekton Triggers for event-driven workflows
- Applies custom tasks and pipelines from `tekton/` directory
- Waits for all pods to be ready before completing

### cleanup.sh
- Deletes KinD cluster if it exists
- Safe to run multiple times (idempotent)

### setup.sh
- Main orchestration script
- Validates prerequisites (docker, kubectl, kind)
- Calls component scripts in correct order
- Provides user-friendly output and next steps

## Makefile Targets

The Makefile provides a clean interface for common operations:
- `make help` - Display all available targets
- `make setup` - Complete environment setup (kind + tekton + verify)
- `make setup-kind` - Create KinD cluster
- `make setup-tekton` - Install Tekton
- `make verify` - Verify environment health
- `make status` - Show environment status
- `make clean` - Cleanup environment

## Kubernetes Context

After running `make setup`, the kubectl context will be automatically set to:
```
kind-ctf-cluster
```

All kubectl commands will target this cluster by default.

## Testing Changes

When modifying setup scripts:

1. **Test cleanup**: `make clean`
2. **Test full setup**: `make setup`
3. **Verify**: `make verify`
4. **Check individual components**:
   ```bash
   kubectl get pods -A
   kubectl get tasks
   kubectl get pipelines
   ```

## Common Issues

### Port Conflicts
If ports 30000/30001 are in use, modify `scripts/setup-kind.sh`:
```yaml
extraPortMappings:
- containerPort: 30000
  hostPort: 30000  # Change to available port
```

### Tekton Installation Failures
- Ensure cluster is fully ready before installing Tekton
- Check network connectivity to `storage.googleapis.com`
- Verify kubectl context: `kubectl config current-context`

### Cluster Already Exists
- Run `make clean` first to remove existing cluster
- Or use different cluster name: `CLUSTER_NAME=ctf2 make setup`

## CTF Participant Workflow

Participants will:
1. Clone this repository
2. Run `make setup` to provision their environment
3. Work on challenges using Tekton pipelines
4. Use `make status` to check their environment
5. Use `make clean` to reset if needed

## Prerequisites for Development

Required tools:
- Docker (container runtime)
- kubectl (Kubernetes CLI)
- kind (Kubernetes in Docker)
- make (build automation)
- bash (script execution)

All scripts assume bash and use `set -euo pipefail` for safety.
