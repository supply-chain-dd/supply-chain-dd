# Supply Chain CTF Environment

This repository contains a Capture The Flag (CTF) environment focused on supply chain security. Participants will work through challenges involving Kubernetes, Tekton Pipelines, container registries, and Git-based workflows.

## Quick Start

### Prerequisites

Ensure you have the following installed:
- **Docker** or **Podman**: Container runtime
- **kubectl**: Kubernetes command-line tool
- **kind**: Kubernetes in Docker (https://kind.sigs.k8s.io/)
- **helm**: Kubernetes package manager (https://helm.sh/)
- **cosign**: Container signing tool (https://docs.sigstore.dev/cosign/installation/) - Required for Tekton Chains
- **make**: Build automation tool

### Setup

Run the complete environment setup:

```bash
make setup
```

This will:
1. Create a KinD cluster named `ctf-cluster`
2. Install Gitea (self-hosted Git service)
3. Install Tekton Pipelines and Triggers
4. Deploy a local Docker registry with TLS

After setup completes, you'll see important configuration instructions. **Pay attention to the TLS registry configuration instructions** displayed at the end.

### Configure Registry TLS (Required)

Before using the registry, configure TLS trust:

```bash
make configure-registry-tls
```

This interactive helper will guide you through installing the registry's self-signed certificate.

### Next Steps

Once the environment is set up and the registry is configured, proceed to set up the CTF challenges:

```bash
make setup-ctf-challenge
```

Then follow the detailed instructions in **[challenges/challenge1/SETUP.md](challenges/challenge1/SETUP.md)** to complete the victim repository setup and webhook configuration.

## Environment Details

After setup, you'll have access to:

- **Kubernetes Cluster**: `kind-ctf-cluster` (via kubectl)
- **Gitea Web UI**: http://localhost:30002
  - Username: `ctf-admin`
  - Password: `CTFSecurePass123!`
- **Gitea SSH**: ssh://git@localhost:30003
- **Docker Registry**: https://localhost:30000
  - Username: `ctf-admin`
  - Password: `CTFRegistryPass123!`

## Useful Commands

```bash
make status               # Show environment status
make verify               # Verify environment is working
make verify-registry      # Verify registry is working
make setup-tektonchains   # Install Tekton Chains for attestation
make verify-tektonchains  # Verify Tekton Chains installation
make clean                # Cleanup environment and start fresh
make help                 # Display all available commands
```

## CTF Challenges

This environment contains multiple supply chain security challenges:

### Challenge 1: Tekton Token Theft (PWN Request Attack)
**Difficulty**: Medium  
**Type**: CI/CD Pipeline Security, RBAC Bypass

Attack a vulnerable Tekton pipeline to steal secrets via ServiceAccount token theft.

**Setup**: See [challenges/challenge1/SETUP.md](challenges/challenge1/SETUP.md)

**Flag**: `FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us:NEXT:registry_layer_leak}`

---

### Challenge 2: Container Image Layer Leak
**Difficulty**: Medium  
**Type**: Container Security, Git History Exposure

Exploit leaked git history in container image layers to extract secrets.

**Setup**:
```bash
make setup-challenge2
make verify-challenge2
```

**Note**: Challenge 2 setup also seeds the `golang:1.25-alpine` base image to the registry for Challenge 3.

**Documentation**: [challenges/challenge2/ATTACK2-README.md](challenges/challenge2/ATTACK2-README.md)

**Flag**: `FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}`

---

### Challenge 3: Malware in Base Image
**Difficulty**: Hard  
**Type**: Supply Chain Attack, Base Image Poisoning

Poison a base container image in the registry to inject malware into production builds.

**Setup**: See [challenges/challenge3/SETUP.md](challenges/challenge3/SETUP.md)

**Flag**: `FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}`

---

### Challenge Progression

The challenges are designed to be completed in sequence, with each providing credentials or hints for the next:

```
Challenge 1 (Tekton PWN)
    ↓ (steal registry credentials)
Challenge 2 (Layer Leak)
    ↓ (seeds golang base image + discover victim uses local registry)
Challenge 3 (Base Image Poisoning)
    ↓ (poison base image → inject malware into production)
Challenge 4 (Coming soon - GitOps Compromise)
```

## Supply Chain Security Tools

### Tekton Chains (Provenance & Attestation)

Tekton Chains automatically generates and signs provenance for your pipeline runs, enabling supply chain security and attestation verification.

**Installation**:
```bash
make setup-tektonchains
make verify-tektonchains
```

**Features**:
- Automatically generates cryptographically signed provenance for PipelineRuns
- Stores attestations in OCI registries
- Supports in-toto and SLSA provenance formats
- Compatible with AMPEL and Conforma for policy enforcement
- Enables deep inspection of pipeline execution
- Uses Cosign for signing (industry standard)
- Public key saved to `cosign.pub` for signature verification

**Configuration**:
The setup automatically configures Tekton Chains with:
- Format: `in-toto` (AMPEL/Conforma compatible)
- Storage: `oci` (stores in OCI registry)
- Deep inspection: `enabled`

**Documentation**: 
- [TEKTON-CHAINS.md](TEKTON-CHAINS.md) - Complete guide to Tekton Chains usage and configuration
- [IMAGE-SIGNING-SBOM.md](IMAGE-SIGNING-SBOM.md) - Image signing and SBOM generation guide

**Pipelines with Automatic Attestation**:
- `pr-quality-check-pipeline` (Challenge 1) - PipelineRun provenance
- `push-build-pipeline` (Challenge 2) - PipelineRun provenance + optional image signing

**Image Signing**: For automatic image signing and SBOM generation, use the Chains-compatible tasks:
```bash
kubectl apply -f challenges/challenge2/tekton/tasks/build-tasks-with-chains.yaml
```
See [IMAGE-SIGNING-SBOM.md](IMAGE-SIGNING-SBOM.md) for details.

## Troubleshooting

### Environment won't start
```bash
make clean && make setup
```

### Can't access Gitea
```bash
# Verify services are running
make status

# Check if Gitea pods are ready
kubectl get pods -n gitea
```

### Registry TLS issues
```bash
# Reconfigure TLS trust
make configure-registry-tls

# Verify registry access
make verify-registry
```

## Contributing

Interested in contributing? See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**For AI Agents**: See [AGENTS.md](AGENTS.md) for documentation update requirements.

## Support

For issues or questions, please open an issue in this repository.
