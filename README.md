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
4. Install Tekton via Helm
5. Deploy a simple registry

## Individual Setup Steps

If you prefer to set up components individually:

```bash
# 1. Create KinD cluster
make setup-kind
# or: cd setup && ./scripts/setup-kind.sh

# 2. Install Gitea
make setup-gitea
# or: cd setup && ./scripts/setup-gitea.sh

# 3. Install Tekton
make setup-tekton
# or: cd setup && ./scripts/setup-tekton.sh

# 4. Deploy registry
make setup-registry
# or: cd setup && ./scripts/setup-registry.sh
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

# Check Registry service
kubectl get pods,svc -n registry

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
- **Gitea Admin Username**: ctf-admin
- **Gitea Admin Password**: CTFSecurePass123!
- **Registry API**: https://localhost:30000
- **Registry Username**: ctf-admin
- **Registry Password**:CTFRegistryPass123!

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
├── Makefile                    # Main automation commands
├── setup/                      # Setup scripts and configurations
│   ├── setup.sh                # Main setup script
│   └── scripts/                # Setup and utility scripts
│       ├── setup-kind.sh       # KinD cluster setup
│       ├── setup-gitea.sh      # Gitea installation
│       ├── setup-tekton.sh     # Tekton Pipelines installation
│       ├── setup-registry.sh   # Docker registry setup
│       └── cleanup.sh          # Environment cleanup
├── tekton/                     # Tekton configurations
│   ├── tasks/                  # Vulnerable Tekton tasks
│   ├── pipelines/              # Vulnerable Tekton pipelines
│   ├── triggers/               # Vulnerable event listeners
│   └── challenges/             # CTF challenges
│       ├── challenge1/         # Attack #1: Tekton Token Theft
│       ├── challenge2/         # Attack #2: Container Layer Leak
│       └── victim-repo-sample/ # Shared victim application
├── gitea/                      # Gitea configurations
├── security/                   # Security policies (Kyverno, NetworkPolicy, RBAC)
├── REGISTRY.md                 # Registry setup documentation
└── SECURITY-GUIDE.md           # Security tools guide
```

## CTF Challenges

This repository contains multiple supply chain security challenges:

### Challenge 1: Tekton Token Theft (PWN Request Attack)
**Difficulty**: Medium  
**Type**: CI/CD Pipeline Security, RBAC Bypass  
**Location**: `tekton/challenges/challenge1/`

Attack a vulnerable Tekton pipeline to steal secrets via ServiceAccount token theft.

**Setup**:
```bash
make setup-ctf-challenge      # Deploy vulnerable version
# OR
make setup-ctf-challenge-secure  # Deploy secure version
```

**Documentation**:
- [CTF Challenge Guide](tekton/challenges/challenge1/CTF-CHALLENGE-GUIDE.md) - Participant walkthrough
- [Attack Analysis](tekton/challenges/challenge1/ATTACK-ANALYSIS.md) - Technical deep-dive
- [Security Guide](tekton/challenges/challenge1/security/README.md) - Prevention & detection

**Flag**: `FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us:NEXT:registry_layer_leak}`

---

### Challenge 2: Container Image Layer Leak
**Difficulty**: Medium  
**Type**: Container Security, Git History Exposure  
**Location**: `tekton/challenges/challenge2/`

Exploit leaked git history in container image layers to extract secrets.

**Setup**:
```bash
make setup-challenge2          # Build and push vulnerable image
make verify-challenge2         # Run automated tests
```

**Documentation**:
- [Challenge README](tekton/challenges/challenge2/ATTACK2-README.md) - Overview and objectives
- [Exploitation Guide](tekton/challenges/challenge2/ATTACK2-EXPLOITATION-GUIDE.md) - Step-by-step walkthrough
- [Setup Summary](tekton/challenges/challenge2/ATTACK2-SUMMARY.md) - Technical details

**Flag**: `FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}`

### Challenge 3: Base image poisoning

### Challenge 4: Deployment pipeline contamination

### Challenge 5: To come
---

### Challenge Progression

The challenges are designed to be completed in sequence:

```
Challenge 1 (Tekton PWN)
    ↓ (steal registry credentials)
Challenge 2 (Layer Leak)
    ↓ (hint: webhook_c0nf1g_1nj3ct10n)
Challenge 3 (Base image poisoning)
```

Each challenge provides credentials or hints for the next one.

## Support

For issues or questions about the environment setup, please open an issue in this repository.
