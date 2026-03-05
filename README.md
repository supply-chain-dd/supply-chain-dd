# Supply Chain CTF Environment

This repository contains the setup scripts and configuration for a Capture The Flag (CTF) exercise focused on supply chain security. Each participant will receive a clone of this repository and set up a local Kubernetes environment with Gitea, a self-hosted Git service.

## Prerequisites

Before setting up the CTF environment, ensure you have the following installed:

- **Docker**: Container runtime
- **kubectl**: Kubernetes command-line tool
- **kind**: Kubernetes in Docker (https://kind.sigs.k8s.io/)
- **helm**: Kubernetes package manager (https://helm.sh/)

### Installing Prerequisites

**macOS (using Homebrew):**
```bash
brew install docker kubectl kind helm
```

**Linux:**
```bash
# Docker - follow official docs: https://docs.docker.com/engine/install/
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Quick Start

To set up the complete CTF environment:

```bash
# Using make (recommended)
make setup

# Or using the setup script directly
./setup.sh
```

This will:
1. Create a KinD cluster named `ctf-cluster`
2. Install Gitea via Helm
3. Configure Gitea with default CTF credentials

## Individual Setup Steps

If you prefer to set up components individually:

```bash
# 1. Create KinD cluster
make setup-kind
# or: cd setup && ./scripts/setup-kind.sh

# 2. Install Gitea
make setup-gitea
# or: cd setup && ./scripts/setup-gitea.sh
```

## Verify Installation

Check that everything is working correctly:

```bash
make verify
```

Or manually verify:

```bash
# Check cluster is running
kubectl cluster-info

# Check Gitea pods are running
kubectl get pods -n gitea

# Check Gitea service
kubectl get svc -n gitea

# List all resources
kubectl get all -A
```

## Environment Status

Check the current state of your environment:

```bash
make status
```

## Cleanup

To remove the CTF environment and start fresh:

```bash
make clean
```

## Environment Details

- **Cluster Name**: `ctf-cluster`
- **Kubernetes Version**: v1.27.3 (configurable)
- **Gitea Version**: 10.6.1 (configurable)
- **Gitea Web UI**: http://localhost:30002
- **Gitea SSH**: ssh://git@localhost:30003
- **Admin Username**: ctf-admin
- **Admin Password**: CTFSecurePass123!

## Customization

You can customize the environment by setting environment variables:

```bash
# Use a different cluster name
CLUSTER_NAME=my-cluster make setup

# Use a different Gitea version
GITEA_VERSION=10.5.0 make setup-gitea

# Use different ports
GITEA_HTTP_PORT=30010 GITEA_SSH_PORT=30011 make setup-gitea
```

## Useful Commands

```bash
# View all pods across namespaces
kubectl get pods -A

# View Gitea pods
kubectl get pods -n gitea

# View Gitea service
kubectl get svc -n gitea

# Access Gitea web UI
open http://localhost:30002  # macOS
xdg-open http://localhost:30002  # Linux

# View Gitea logs
kubectl logs -n gitea -l app=gitea -f

# Get admin password (if forgotten)
echo "CTFSecurePass123!"

# Delete and recreate the environment
make clean && make setup
```

## Troubleshooting

### Cluster won't start
```bash
# Delete and recreate
make clean
make setup
```

### Gitea pods not ready
```bash
# Check pod status
kubectl get pods -n gitea
kubectl describe pod <pod-name> -n gitea

# Check helm release
helm list -n gitea
helm status gitea -n gitea
```

### Can't access Gitea web UI
```bash
# Verify service is running
kubectl get svc -n gitea

# Check if port 30002 is listening
curl http://localhost:30002

# Forward port manually if needed
kubectl port-forward -n gitea svc/gitea-http 30002:3000
```

### Port conflicts
If ports 30002 or 30003 are already in use:
```bash
# Use different ports
GITEA_HTTP_PORT=30010 GITEA_SSH_PORT=30011 make setup-gitea

# Or edit setup/scripts/setup-kind.sh to use different ports
```

## Project Structure

```
.
├── Makefile              # Main automation commands
├── setup/                # Setup scripts and configurations
│   ├── setup.sh          # Main setup script
│   └── scripts/          # Setup and utility scripts
│       ├── setup-kind.sh # KinD cluster setup
│       ├── setup-gitea.sh# Gitea installation
│       └── cleanup.sh    # Environment cleanup
├── gitea/                # Gitea configurations
│   ├── repos/            # Pre-configured repository definitions
│   └── configs/          # Custom Gitea configuration files
└── k8s/                  # Kubernetes manifests
    └── base/             # Base configurations
```

## CTF Challenges

*(Challenge details and objectives will be added here)*

## Support

For issues or questions about the environment setup, please open an issue in this repository.
