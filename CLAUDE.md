# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Capture The Flag (CTF) environment setup project focused on supply chain security. The project provides automated scripts to provision a complete Kubernetes environment for CTF participants, including:

- A KinD (Kubernetes in Docker) cluster
- Gitea self-hosted Git service for Git-based supply chain scenarios
- Pre-configured repositories and CTF challenges

## Architecture

### Component Stack
1. **KinD Cluster**: Local Kubernetes cluster running in Docker containers
   - Configured with port mappings (30000, 30001, 30002, 30003) for service access
   - Custom containerd configuration for registry integration
   - Single control-plane node setup

2. **Gitea**: Self-hosted Git service (similar to GitHub/GitLab)
   - Installed via Helm chart
   - Web UI accessible at http://localhost:30002
   - SSH access available at ssh://git@localhost:30003
   - SQLite database for simplicity (no PostgreSQL dependency)
   - Persistent storage for Git repositories
   - Pre-configured admin credentials for CTF environment

### Directory Structure
```
├── setup/                # Setup scripts and configurations
│   ├── setup.sh          # Main orchestration script
│   └── scripts/          # Shell scripts for environment setup
│       ├── setup-kind.sh # KinD cluster provisioning
│       ├── setup-gitea.sh# Gitea installation via Helm
│       └── cleanup.sh    # Environment teardown
├── gitea/                # Gitea configurations
│   ├── repos/            # Pre-configured repository definitions
│   └── configs/          # Custom Gitea configuration files
├── k8s/                  # Kubernetes manifests
│   └── base/             # Base configurations
└── Makefile              # Primary automation interface
```

## Development Commands

### Environment Setup
```bash
# Complete setup (creates cluster + installs Gitea)
make setup

# Individual components
make setup-kind      # Create KinD cluster only
make setup-gitea     # Install Gitea only

# Alternative: use main script
cd setup && ./setup.sh
```

### Verification and Status
```bash
make verify         # Verify environment is working
make status         # Show detailed status
```

### Cleanup
```bash
make clean                        # Delete cluster and cleanup
cd setup && ./scripts/cleanup.sh  # Alternative cleanup method
```

### Configuration Variables
Environment variables that control setup:
- `CLUSTER_NAME` (default: `ctf-cluster`) - KinD cluster name
- `GITEA_VERSION` (default: `10.6.1`) - Gitea Helm chart version
- `GITEA_HTTP_PORT` (default: `30002`) - Gitea web UI port
- `GITEA_SSH_PORT` (default: `30003`) - Gitea SSH port
- `KIND_VERSION` (default: `v1.27.3`) - Kubernetes version for KinD

Example:
```bash
CLUSTER_NAME=my-ctf GITEA_VERSION=10.5.0 make setup
```

## Adding CTF Challenges

### Gitea Repositories
CTF challenges can be created as Git repositories with specific vulnerabilities or scenarios:

**Example Challenge Ideas:**
- **Malicious Commits**: Repository with hidden backdoors in commit history
- **Compromised Dependencies**: Projects with vulnerable or malicious dependencies
- **Leaked Secrets**: Repositories containing accidentally committed credentials
- **Branch Protection Bypass**: Scenarios testing Git workflow security
- **Hook Exploits**: Custom Git hooks with security implications

### Pre-configured Repositories
Place repository configurations in `gitea/repos/`:
```bash
gitea/repos/
├── challenge-1/
│   ├── README.md
│   └── src/
└── challenge-2/
    └── ...
```

Repositories can be imported into Gitea via API or manually after setup.

## Script Architecture

### setup-kind.sh
- Validates KinD is installed
- Checks for existing cluster to prevent conflicts
- Creates cluster with custom config (port mappings, registry config)
- Waits for cluster readiness using `kubectl wait`

### setup-gitea.sh
- Checks for Helm installation
- Adds Gitea Helm repository
- Creates `gitea` namespace
- Installs Gitea via Helm with custom values:
  - NodePort service type for local access
  - Ports 30002 (HTTP) and 30003 (SSH)
  - Custom admin credentials (ctf-admin / CTFSecurePass123!)
  - SQLite database (no PostgreSQL dependency)
  - Persistent storage enabled
- Waits for all pods to be ready before completing
- Displays access information

### cleanup.sh
- Uninstalls Gitea Helm release if it exists
- Deletes gitea namespace
- Deletes KinD cluster if it exists
- Safe to run multiple times (idempotent)

### setup.sh
- Main orchestration script
- Validates prerequisites (docker, kubectl, kind, helm)
- Calls component scripts in correct order
- Provides user-friendly output with Gitea access information

## Makefile Targets

The Makefile provides a clean interface for common operations:
- `make help` - Display all available targets
- `make setup` - Complete environment setup (kind + gitea + verify)
- `make setup-kind` - Create KinD cluster
- `make setup-gitea` - Install Gitea
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
   kubectl get pods -n gitea
   kubectl get svc -n gitea
   helm list -n gitea
   ```

## Common Issues

### Port Conflicts
If ports 30002/30003 are in use:
```bash
# Use different ports
GITEA_HTTP_PORT=30010 GITEA_SSH_PORT=30011 make setup-gitea
```

Or modify `setup/scripts/setup-kind.sh`:
```yaml
extraPortMappings:
- containerPort: 30002
  hostPort: 30010  # Change to available port
```

### Gitea Installation Failures
- Ensure cluster is fully ready before installing Gitea
- Check Helm is installed: `helm version`
- Verify kubectl context: `kubectl config current-context`
- Check Helm repository: `helm repo list`
- View Helm release status: `helm status gitea -n gitea`

### Can't Access Gitea
- Verify service: `kubectl get svc -n gitea`
- Check pods are running: `kubectl get pods -n gitea`
- Test connectivity: `curl http://localhost:30002`
- Check port forwarding if needed: `kubectl port-forward -n gitea svc/gitea-http 30002:3000`

### Cluster Already Exists
- Run `make clean` first to remove existing cluster
- Or use different cluster name: `CLUSTER_NAME=ctf2 make setup`

## CTF Participant Workflow

Participants will:
1. Clone this repository
2. Run `make setup` to provision their environment
3. Access Gitea at http://localhost:30002
4. Login with credentials: ctf-admin / CTFSecurePass123!
5. Work on Git-based supply chain security challenges
6. Use `make status` to check their environment
7. Use `make clean` to reset if needed

## Prerequisites for Development

Required tools:
- Docker (container runtime)
- kubectl (Kubernetes CLI)
- kind (Kubernetes in Docker)
- helm (Kubernetes package manager)
- make (build automation)
- bash (script execution)

All scripts assume bash and use `set -euo pipefail` for safety.
