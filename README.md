# Supply Chain CTF Environment

This repository contains the setup scripts and configuration for a Capture The Flag (CTF) exercise focused on supply chain security. Each participant will receive a clone of this repository and set up a local Kubernetes environment with Tekton pipelines.

## Prerequisites

Before setting up the CTF environment, ensure you have the following installed:

- **Docker**: Container runtime
- **kubectl**: Kubernetes command-line tool
- **kind**: Kubernetes in Docker (https://kind.sigs.k8s.io/)

### Installing Prerequisites

**macOS (using Homebrew):**
```bash
brew install docker kubectl kind
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
2. Install Tekton Pipelines and Triggers
3. Apply any custom Tekton tasks and pipelines

## Individual Setup Steps

If you prefer to set up components individually:

```bash
# 1. Create KinD cluster
make setup-kind
# or: ./scripts/setup-kind.sh

# 2. Install Tekton
make setup-tekton
# or: ./scripts/setup-tekton.sh
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

# Check Tekton pods are running
kubectl get pods -n tekton-pipelines

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
- **Tekton Pipelines Version**: v0.53.0 (configurable)
- **Tekton Triggers Version**: v0.25.0 (configurable)

## Customization

You can customize the environment by setting environment variables:

```bash
# Use a different cluster name
CLUSTER_NAME=my-cluster make setup

# Use a different Tekton version
TEKTON_PIPELINE_VERSION=v0.50.0 make setup-tekton
```

## Useful Commands

```bash
# View all pods across namespaces
kubectl get pods -A

# View Tekton pipeline runs
kubectl get pipelineruns

# View Tekton tasks
kubectl get tasks

# Follow logs of a pipeline run
tkn pipelinerun logs <pipelinerun-name> -f

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

### Tekton pods not ready
```bash
# Check pod status
kubectl get pods -n tekton-pipelines
kubectl describe pod <pod-name> -n tekton-pipelines
```

### Port conflicts
If ports 30000 or 30001 are already in use, edit `scripts/setup-kind.sh` to use different ports.

## Project Structure

```
.
├── Makefile              # Main automation commands
├── setup.sh              # Main setup script
├── scripts/              # Setup and utility scripts
│   ├── setup-kind.sh     # KinD cluster setup
│   ├── setup-tekton.sh   # Tekton installation
│   └── cleanup.sh        # Environment cleanup
├── tekton/               # Tekton resources
│   ├── tasks/            # Custom Tekton tasks
│   └── pipelines/        # Custom Tekton pipelines
└── k8s/                  # Kubernetes manifests
    └── base/             # Base configurations
```

## CTF Challenges

*(Challenge details and objectives will be added here)*

## Support

For issues or questions about the environment setup, please open an issue in this repository.
