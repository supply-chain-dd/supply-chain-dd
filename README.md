# Supply Chain CTF Environment

This repository contains a Capture The Flag (CTF) environment focused on supply chain security. Participants will work through challenges involving Kubernetes, Tekton Pipelines, container registries, and Git-based workflows.

## Quick Start

### Prerequisites

Ensure you have the following installed:
- **Docker** or **Podman**: Container runtime
- **kubectl**: Kubernetes command-line tool
- **kind**: Kubernetes in Docker (https://kind.sigs.k8s.io/)
- **helm**: Kubernetes package manager (https://helm.sh/)
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
make status          # Show environment status
make verify          # Verify environment is working
make verify-registry # Verify registry is working
make clean           # Cleanup environment and start fresh
make help            # Display all available commands
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

**Documentation**: [challenges/challenge2/ATTACK2-README.md](challenges/challenge2/ATTACK2-README.md)

**Flag**: `FLAG{l4y3r_l34k_g1t_h1st0ry:NEXT:webhook_c0nf1g_1nj3ct10n}`

---

### Challenge Progression

The challenges are designed to be completed in sequence, with each providing credentials or hints for the next:

```
Challenge 1 (Tekton PWN)
    ↓ (steal registry credentials)
Challenge 2 (Layer Leak)
    ↓ (discover webhook configuration)
Challenge 3+ (Coming soon)
```

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
