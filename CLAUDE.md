# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**IMPORTANT**: See [AGENTS.md](AGENTS.md) for detailed documentation update requirements. All changes must update corresponding documentation files (README.md, CLAUDE.md, challenge docs).

## Project Overview

This is a Capture The Flag (CTF) environment setup project focused on supply chain security. The project provides automated scripts to provision a complete Kubernetes environment for CTF participants, including:

- A KinD (Kubernetes in Docker) cluster
- Gitea self-hosted Git service for Git-based supply chain scenarios
- A container registry
- A CI/CD Tekton pipeline
- Pre-configured repositories and CTF challenges
- Step-by-step (demo-magic) scripts to show-case the attacks, then to detect and prevent them

## Attacks show-cased

| Attack | Description | Detection tools | Prevention tools |
|--------|-------------|-----------------|------------------|
|Pull Request Target |Execution of malicious code from the attacker's fork on the CI/CD pipeline, resulting in hacker extracting tokens and secrets|Zizmor (workflow security analysis), Scorecard (repo security posture), Audicia (RBAC abuse from audit logs), Kubescape | Kyverno (pipeline policies), Network Policies (egress restrictions), RBAC (least privilege), AMPEL (attestation enforcement) |
|Leaked secrets within container images|Sensitive credentials and secrets embedded in container image layers, exposing them to anyone with image access|Kubescape (image scanning), Baseline (project security baseline), Falco (runtime secret access detection) | Kyverno (block images with secrets), SBOM (transparency), Signatures (image verification), Secret scanning in CI/CD |
|Malware in base image |Compromised or malicious base container images containing backdoors or malware|Kubescape (vuln scanning), Guac (SBOM + provenance analysis), Scorecard (base image repo security), AMPEL (verify build attestations) | Kyverno (trusted registry/image policies), SBOM (component transparency), Signatures (image signing/verification), VEX (exploit context), Guac (supply chain graph) |
|Compromised Continuous Deployment (GitOps pipeline)|Attacker gains control of GitOps deployment pipeline to deploy malicious workloads|Falco (runtime anomaly detection), Audicia (RBAC abuse from audit logs), Kubescape (config scanning), AMPEL (deployment attestation verification) | Kyverno (deployment admission policies), RBAC (strict permissions), Network Policies (lateral movement prevention), SBOM, Signatures (artifact verification), Dependabot/Renovate (toolchain updates) |

## Architecture


## # Challenge structure
Each challenge must contain:
* A `SETUP.md` file that explains what needs to be setup in the environment so that the attack can be performed 
* A `CTF-CHALLENGE-GUIDE.md` that explains how to conduct the attack
* A `ATTACK-ANALYSIS.md` that explains the attack, eventually contains real world attack examples of the same type
* A `SECURITY-GUIDE.md` that explains how to detect it and prevent it
* All scripts, source code, manifests needed to setup the attack, conduct it, detect and prevent it
* Interactive demo scripts (`*-demo.sh`) using demo-magic for detection/prevention walkthroughs. Each must be referenced in `SECURITY-GUIDE.md`.

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

3. **Docker Registry**: Local container registry (registry:3)
   - Deployed as Kubernetes Deployment in `registry` namespace
   - TLS/HTTPS with self-signed certificate
   - Basic authentication with configurable credentials
   - Accessible externally at https://localhost:30000
   - Accessible internally at https://registry.registry.svc.cluster.local:5000
   - Persistent storage via PersistentVolumeClaim (10Gi)
   - Credentials stored in ctf-flag secret for CTF challenge integration
   - CA certificate saved to `certs/registry.crt` for client configuration

4. **Tekton Pipeline**: Cloud-native, CI/CD pipeline 
   - Installed via Helm chart


### Directory Structure
```
├── setup/                          # Setup scripts and configurations
│   ├── setup.sh                    # Main orchestration script
│   └── scripts/                    # Shell scripts for environment setup
│       ├── setup-kind.sh           # KinD cluster provisioning
│       ├── setup-gitea.sh          # Gitea installation via Helm
│       ├── setup-tekton.sh         # Tekton Pipelines installation
│       ├── setup-tektonchains.sh   # Tekton Chains installation and configuration
│       ├── setup-registry.sh       # Registry deployment with TLS
│       ├── configure-registry-tls.sh # TLS trust configuration helper
│       └── cleanup.sh              # Environment teardown
├── challenges/                     # CTF Challenges
│   ├── challenge1/                 # Attack #1: Tekton Token Theft
│   │   ├── SETUP.md                # Challenge setup instructions
│   │   ├── CTF-CHALLENGE-GUIDE.md  # Participant walkthrough
│   │   ├── ATTACK-ANALYSIS.md      # Technical analysis
│   │   ├── SECURITY-GUIDE.md       # Detection and prevention
│   │   ├── tekton/                 # Vulnerable Tekton resources
│   │   │   ├── tasks/              # Vulnerable tasks
│   │   │   ├── pipelines/          # Vulnerable pipelines
│   │   │   └── triggers/           # Vulnerable event listeners
│   │   ├── security/               # Prevention & detection
│   │   │   ├── rbac/
│   │   │   ├── kyverno-policies/
│   │   │   └── network-policies/
│   │   └── tekton-patched/         # Secured configurations
│   ├── challenge2/                 # Attack #2: Container Layer Leak
│   │   ├── ATTACK-ANALYSIS.md
│   │   ├── CTF-CHALLENGE-GUIDE.md
│   │   ├── SETUP.md
│   │   ├── SECURITY-GUIDE.md
│   │   ├── tekton/
│   │   │   ├── manual-pipelinerun.yaml              # Manual trigger (standard pipeline)
│   │   │   ├── manual-pipelinerun-with-chains.yaml  # Manual trigger (Chains+Conforma pipeline)
│   │   │   ├── pipelines/
│   │   │   │   ├── push-build-pipeline.yaml          # Standard build pipeline
│   │   │   │   └── push-build-pipeline-with-chains.yaml # Chains+Conforma pipeline
│   │   │   ├── registry-docker-config-secret.yaml
│   │   │   ├── tasks/
│   │   │   │   ├── build-tasks.yaml                 # Standard build/push tasks
│   │   │   │   ├── build-tasks-with-chains.yaml     # Chains-aware tasks + SBOM generation
│   │   │   │   ├── verify-source-task.yaml          # Source verification + VSA tasks
│   │   │   │   ├── quality-check-task.yaml
│   │   │   │   └── supporting-tasks.yaml
│   │   │   └── triggers/
│   │   │       └── push-eventlistener.yaml
│   │   └── test-attack2.sh
│   ├── challenge3/                 # Attack #3: Base Image Poisoning
│   │   ├── ATTACK-ANALYSIS.md      # Technical analysis and real-world examples
│   │   ├── CTF-CHALLENGE-GUIDE.md  # Step-by-step attack execution + defense walkthrough
│   │   ├── SETUP.md                # Environment setup for attack
│   │   ├── SECURITY-GUIDE.md       # Detection, prevention, interactive demos
│   │   ├── sbom-comparison-demo.sh # SBOM comparison demo (clean vs poisoned)
│   │   ├── defense-demo.sh         # End-to-end defense demo
│   │   ├── tekton/                 # Vulnerable pipeline configs
│   │   ├── tekton-patched/         # Secured pipeline with all defense layers
│   │   │   ├── tasks/
│   │   │   │   ├── verify-base-image-task.yaml      # Pre-build base image verification
│   │   │   │   └── sign-image-keyless-task.yaml     # Keyless signing (Fulcio + Rekor)
│   │   │   ├── pipelines/
│   │   │   │   └── push-build-pipeline-with-chains-secure.yaml
│   │   │   ├── triggers/
│   │   │   │   └── push-eventlistener-secure.yaml
│   │   │   ├── manual-pipelinerun-with-chains-secure.yaml
│   │   │   ├── Dockerfile           # Digest-pinned multi-stage build
│   │   │   └── .dockerignore        # Allowlist pattern
│   │   └── security/               # Post-pipeline policies
│   │       ├── configmaps/
│   │       │   └── golang-baseline-sbom.yaml  # SBOM baseline for comparison
│   │       ├── kyverno-policies/
│   │       │   ├── require-image-digest.yaml
│   │       │   └── require-sbom-attestation.yaml
│   │       ├── conforma-policies/
│   │       │   └── sbom-baseline-check.rego
│   │       └── ampel-policies/
│   │           └── verify-build-artifacts.hjson
│   ├── challenge4/                 # Attack #4: GitOps Compromise (Coming soon)
│   └── victim-repo-sample/         # Shared victim application
├── gitea/                          # Gitea configurations
├── certs/                          # Registry TLS certificates (generated)
│   └── registry.crt                # CA certificate for client trust
├── Makefile                        # Primary automation interface
├── REGISTRY.md                     # Registry setup and usage documentation
├── TEKTON-CHAINS.md                # Tekton Chains attestation guide
├── IMAGE-SIGNING-SBOM.md           # Image signing and SBOM generation guide
└── SECURITY-GUIDE.md               # Security tools and prevention guide
```

## Development Commands

### Environment Setup
```bash
# Complete setup (creates cluster + installs Gitea)
make setup

# Individual components
make setup-kind         # Create KinD cluster only
make setup-gitea        # Install Gitea only
make setup-tekton       # Install Tekton Pipelines and Triggers
make setup-tektonchains # Install Tekton Chains for attestation
make setup-registry     # Setup Docker registry

```

### Verification and Status
```bash
make verify               # Verify environment is working
make verify-registry      # Verify registry is working
make verify-tektonchains  # Verify Tekton Chains installation
make status               # Show detailed status
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
- `TEKTON_CHAINS_VERSION` (default: `v0.26.3`) - Tekton Chains version
- `REGISTRY_NODE_PORT` (default: `30000`) - Registry external access port
- `REGISTRY_USER` (default: `ctf-admin`) - Registry username
- `REGISTRY_PASS` (default: `CTFRegistryPass123!`) - Registry password

Example:
```bash
CLUSTER_NAME=my-ctf GITEA_VERSION=10.5.0 make setup
```



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

### setup-registry.sh
- Creates `registry` namespace
- Generates self-signed TLS certificate with Subject Alternative Names
- Saves CA certificate to `certs/registry.crt` for client configuration
- Creates TLS Secret for HTTPS communication
- Generates htpasswd credentials (using podman, docker, or htpasswd command)
- Creates Secret with registry authentication credentials
- Creates PersistentVolumeClaim for registry storage (10Gi)
- Configures registry for TLS/HTTPS and basic auth
- Deploys registry:3 as a Kubernetes Deployment with TLS enabled
- Creates NodePort Service for external and internal access
- Waits for registry to be ready
- Provides access information and TLS configuration instructions

### configure-registry-tls.sh
- Interactive helper script to configure TLS trust for the registry
- Detects container runtime (Podman or Docker)
- Offers per-registry or system-wide certificate installation
- Automatically installs certificate in the correct location
- Restarts services when needed
- Provides verification commands

### setup-tektonchains.sh
- Installs Tekton Chains for supply chain security
- Configures Chains with AMPEL/Conforma compatible settings:
  - Format: `in-toto` (standard attestation format)
  - Storage: `oci` (stores attestations in OCI registries)
  - Deep inspection: enabled
- Patches chains-config ConfigMap with security settings
- Restarts controller to apply configuration
- Displays configuration summary and next steps
- Enables automatic provenance generation for PipelineRuns

### cleanup.sh
- Cleans up registry namespace if it exists
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

**CLI Tools:**
- `check-cli-tools`   - Check if required CLI tools are installed
- `install-tkn`       - Install Tekton CLI as kubectl plugin
- `install-kubescape` - Install Kubescape CLI as kubectl plugin
- `install-conforma`  - Install Conforma (`ec`) CLI from GitHub releases
- `install-ampel`     - Install Ampel CLI for post-pipeline verification

**Environment Setup:**
- `setup`                      - Complete setup (KinD cluster + Gitea + tekton + registry + verification)
- `setup-kind`                 - Create KinD cluster
- `setup-gitea`                - Install Gitea via Helm
- `setup-tekton`               - Install Tekton Pipelines and Triggers (also enables OCI bundles resolver)
- `setup-tektonchains`         - Install and configure Tekton Chains for supply chain security
- `setup-registry`             - Setup local Docker registry with authentication
- `configure-registry-tls`     - Configure TLS trust for the registry (interactive)
- `setup-ctf-challenge`        - Install Tekton CTF challenge resources (VULNERABLE version)
- `setup-ctf-challenge-secure` - Install Tekton CTF challenge with SECURE configuration
- `setup-challenge2-tekton`    - Deploy challenge2 Tekton resources including Chains-aware pipeline
- `setup-challenge3-tekton-secure` - Deploy Challenge 3 secured Tekton resources (verify-base-image + keyless signing)

**Security Tools:**
- `setup-security-tools` - Deploy all security tools (Kyverno + Kubescape)
- `setup-kyverno`        - Deploy Kyverno policy engine
- `setup-kubescape`      - Deploy Kubescape security scanner
- `setup-conforma`       - Install ec CLI and verify cosign key setup

**Challenge Triggers:**
- `trigger-challenge2-build`             - Run the standard push-build-pipeline (no signing)
- `trigger-challenge2-build-with-chains` - Run push-build-pipeline-with-chains (Tekton Chains + Conforma)
- `trigger-challenge3-build-secure`      - Run Challenge 3 secured pipeline manually

**Security Operations:**
- `security-scan`            - Run all security scans (static analysis + runtime checks)
- `apply-prevention-policies`- Apply Kyverno policies and network policies
- `create-security-policies` - Create security policy files (Kyverno, NetworkPolicy, RBAC)
- `verify-security`          - Verify security tools and policies are working

**Verification:**
- `status`               - Show environment status
- `verify-ctf`           - Verify Tekton CTF challenge installation
- `verify-registry`      - Verify registry is working correctly
- `verify-tektonchains`  - Verify Tekton Chains installation and configuration
- `verify-conforma`      - Verify Conforma (ec CLI) installation and policy resources

**Cleanup:**
- `clean` - Cleanup environment (delete cluster and resources)

## Kubernetes Context

After running `make setup`, the kubectl context will be automatically set to:
```
kind-ctf-cluster
```

All kubectl commands will target this cluster by default.



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

## Docker Registry

### Setup and Access

The project includes a local Docker registry for container image management with TLS encryption:

```bash
# Setup registry (generates self-signed certificate)
make setup-registry

# Configure TLS trust (required before use)
# Use the automated helper (recommended):
make configure-registry-tls

# Or configure manually:
# For Podman:
sudo mkdir -p /etc/containers/certs.d/localhost:30000
sudo cp certs/registry.crt /etc/containers/certs.d/localhost:30000/ca.crt

# For Docker:
sudo mkdir -p /etc/docker/certs.d/localhost:30000
sudo cp certs/registry.crt /etc/docker/certs.d/localhost:30000/ca.crt
sudo systemctl restart docker

# Verify it's working
make verify-registry
```

**Access Points:**
- External (from host): `https://localhost:30000`
- Internal (from cluster): `https://registry.registry.svc.cluster.local:5000`

**Credentials:**
- Username: `ctf-admin` (configurable via `REGISTRY_USER`)
- Password: `CTFRegistryPass123!` (configurable via `REGISTRY_PASS`)

**TLS Certificate:**
- Location: `certs/registry.crt`
- Type: Self-signed (365 days validity)

### Usage Examples

```bash
# Login with podman (after TLS configuration)
podman login localhost:30000 -u ctf-admin -p CTFRegistryPass123!

# Push an image
podman tag nginx:latest localhost:30000/nginx:test
podman push localhost:30000/nginx:test

# List images (with certificate)
curl --cacert certs/registry.crt -u ctf-admin:CTFRegistryPass123! https://localhost:30000/v2/_catalog

# Or skip TLS verification (testing only)
curl -k -u ctf-admin:CTFRegistryPass123! https://localhost:30000/v2/_catalog
```

### CTF Integration

The registry credentials are automatically included in the `ctf-flag` secret in the `ctf-challenge` namespace:
- `registry-url`: Internal cluster URL
- `registry-user`: Registry username
- `registry-password`: Registry password

This allows CTF challenges to interact with the registry for scenarios involving:
- Container image manipulation
- Supply chain attacks via malicious images
- Registry credential theft
- Image signing and verification bypasses

See [REGISTRY.md](REGISTRY.md) for complete documentation.

## CTF Participant Workflow

Participants will:
1. Clone this repository
2. Run `make setup` to provision their environment
3. (Optional) Run `make setup-registry` to enable container registry challenges
4. Access Gitea at http://localhost:30002
5. Login with credentials: ctf-admin / CTFSecurePass123!
6. Work on supply chain security challenges (Git, containers, CI/CD)
7. Use `make status` to check their environment
8. Use `make clean` to reset if needed

## Prerequisites for Development

Required tools:
- **kubectl** (Kubernetes CLI) - Required
- **kind** (Kubernetes in Docker) - Required
- **helm** (Kubernetes package manager) - Required for Gitea
- **cosign** (Container signing tool) - Required for Tekton Chains (https://docs.sigstore.dev/cosign/installation/)
- **podman** or **docker** (container runtime) - Required for registry htpasswd generation
- **make** (build automation) - Required
- **bash** (script execution) - Required

Optional tools:
- **htpasswd** (apache2-utils) - Can be used instead of podman/docker for registry auth
- **curl** (for testing)
- **jq** (JSON processor) - Useful for debugging

All scripts assume bash and use `set -euo pipefail` for safety.

## Working with victim-repo-sample

**IMPORTANT**: The `challenges/victim-repo-sample/` directory contains a `_git` folder (NOT `.git`) to avoid conflicts with the main supply-chain-dd git repository.

**Do NOT run git commands directly in this directory**, as the git history is stored as `_git` and not recognized as a git repository.

**To work with the git history in victim-repo-sample:**
1. Copy the folder to a temporary location
2. Rename `_git` to `.git`
3. Work with git commands in the temporary copy

Example:
```bash
# Copy to temporary location and restore git history
cp -r challenges/victim-repo-sample /tmp/recipe-api-work
mv /tmp/recipe-api-work/_git /tmp/recipe-api-work/.git

# Now safe to use git commands
cd /tmp/recipe-api-work
git log
git show <commit-hash>
```

**The setup scripts automatically handle this conversion:**
- `seed-victim-repo.sh`: Renames `_git` to `.git` before pushing to Gitea
- Build targets in Makefile: Handle the conversion when building images

**Git History Structure:**
- Commit 1 (`26e05de`): Initial commit: Recipe API v1.0
- Commit 2 (`ed9f32e`): Security fix: Remove accidentally committed production secrets
- Commit 3 (`f604902`): Add health and readiness endpoints

Commit 1 and 2 IDs are referenced in challenge documentation and should be kept consistent when updating the repository.

## Documentation Update Requirements

**CRITICAL**: When making changes to this repository, you MUST update documentation:

### Always Update
- **README.md**: For any user-facing changes (new commands, features, challenges)
- **CLAUDE.md**: For architecture, development workflow, or tool changes

### Challenge Folder Changes (`challenges/challengeN/`)
When modifying challenge files, update the appropriate documentation:

| Change Type | Update File |
|-------------|-------------|
| Environment setup, configuration | `SETUP.md` |
| Attack execution steps | `CTF-CHALLENGE-GUIDE.md` |
| Attack explanation, real-world examples | `ATTACK-ANALYSIS.md` |
| Detection/prevention methods | `SECURITY-GUIDE.md` |
| Demo scripts (`*-demo.sh`) | `SECURITY-GUIDE.md` (Interactive Demos section + cross-references) |

**See [AGENTS.md](AGENTS.md) for complete guidelines.**

## Contributing

- **Human contributors**: See [CONTRIBUTING.md](CONTRIBUTING.md)
- **AI agents**: See [AGENTS.md](AGENTS.md)
