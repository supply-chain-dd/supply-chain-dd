# Security Controls for Challenge 4

This directory contains detection and prevention mechanisms for GitOps pipeline attacks.

## Directory Structure

```
security/
├── kyverno-policies/           # Admission control policies
│   ├── require-image-signature.yaml
│   ├── restrict-privileged-containers.yaml
│   └── restrict-high-resources.yaml
├── network-policies/           # Network segmentation
│   └── deny-egress-default.yaml
├── rbac/                       # Least-privilege RBAC
│   └── least-privilege-argocd.yaml
├── falco-rules/                # Runtime detection
│   └── gitops-attacks.yaml
└── README.md
```

## Kyverno Policies

### 1. Image Signature Verification

**File**: `kyverno-policies/require-image-signature.yaml`

**Purpose**: Ensures all container images are cryptographically signed and verified.

**Prevents**:
- Deployment of unsigned images
- Image tampering attacks
- Supply chain compromise via malicious images

**Install**:
```bash
kubectl apply -f kyverno-policies/require-image-signature.yaml
```

### 2. Privileged Container Restrictions

**File**: `kyverno-policies/restrict-privileged-containers.yaml`

**Purpose**: Blocks deployment of privileged containers and enforces pod security standards.

**Prevents**:
- Containers running as root
- Privilege escalation
- Dangerous capabilities (SYS_ADMIN, NET_ADMIN)
- The backdoored deployment from `attack-payloads/backdoored-deployment.yaml`

**Install**:
```bash
kubectl apply -f kyverno-policies/restrict-privileged-containers.yaml
```

**Test**:
```bash
# This should be BLOCKED by Kyverno
kubectl apply -f ../attack-payloads/backdoored-deployment.yaml

# Expected: Error from admission webhook
```

### 3. High Resource Usage Restrictions

**File**: `kyverno-policies/restrict-high-resources.yaml`

**Purpose**: Prevents deployment of containers with excessive CPU/memory requests.

**Prevents**:
- Cryptocurrency mining
- Resource abuse
- The malicious pod from `attack-payloads/malicious-pod.yaml`

**Install**:
```bash
kubectl apply -f kyverno-policies/restrict-high-resources.yaml
```

**Test**:
```bash
# This should be BLOCKED (requests 2+ CPU)
kubectl apply -f ../attack-payloads/malicious-pod.yaml

# Expected: Error about CPU/memory exceeding limits
```

## Network Policies

### Deny-All Egress with Allow-List

**File**: `network-policies/deny-egress-default.yaml`

**Purpose**: Default-deny egress traffic, only allowing specific connections.

**Prevents**:
- Reverse shell connections to attacker servers
- Data exfiltration
- Cryptocurrency mining pool connections
- Arbitrary outbound traffic

**Allowed Traffic**:
- DNS resolution (port 53 UDP)
- PostgreSQL database (port 5432 TCP)
- Redis cache (port 6379 TCP)

**Install**:
```bash
kubectl apply -f network-policies/deny-egress-default.yaml
```

**Test**:
```bash
# Deploy a test pod
kubectl run -n production test-pod --image=alpine --restart=Never -- sleep 3600

# Try to reach external server (should FAIL)
kubectl exec -n production test-pod -- wget -O- http://google.com
# Expected: Connection timeout

# Try to reach allowed service (should SUCCEED)
kubectl exec -n production test-pod -- nc -zv redis-service 6379
```

## RBAC

### Least-Privilege ArgoCD

**File**: `rbac/least-privilege-argocd.yaml`

**Purpose**: Restricts ArgoCD permissions to only what's necessary.

**Differences from Vulnerable Config**:

| Vulnerable | Secure |
|------------|--------|
| ClusterAdmin | Namespace-scoped Role |
| Can create namespaces | Cannot create namespaces |
| Can modify RBAC | Cannot modify RBAC |
| Can access all secrets | Read-only secret access |
| Cluster-wide permissions | Production namespace only |

**Install**:
```bash
kubectl apply -f rbac/least-privilege-argocd.yaml
```

## Falco Rules

### Runtime Attack Detection

**File**: `falco-rules/gitops-attacks.yaml`

**Purpose**: Detects malicious behavior at runtime.

**Detects**:
1. **Reverse Shells**: Netcat, bash /dev/tcp connections
2. **Cryptomining**: xmrig, mining pool connections
3. **Secret Access**: Unauthorized reads of service account tokens
4. **Data Exfiltration**: curl/wget with POST/data
5. **kubectl Usage**: kubectl execution in production pods
6. **Shell Spawning**: Interactive shells in containers
7. **Privilege Escalation**: sudo, su, capability manipulation

**Install**:
```bash
# Add to Falco configuration
kubectl create cm falco-rules -n falco --from-file=gitops-attacks.yaml
kubectl rollout restart -n falco daemonset/falco
```

**Test**:
```bash
# Trigger alert: spawn a shell
kubectl exec -n production recipe-api-xxx -- /bin/bash

# Check Falco logs
kubectl logs -n falco -l app=falco | grep "Shell spawned"
```

## Complete Setup

### Deploy All Security Controls

```bash
# Install Kyverno (if not already installed)
kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.10.0/install.yaml

# Wait for Kyverno to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=300s

# Apply all policies
kubectl apply -f kyverno-policies/
kubectl apply -f network-policies/
kubectl apply -f rbac/

# Verify
kubectl get clusterpolicies
kubectl get networkpolicies -n production
kubectl get roles,rolebindings -n production
```

### Verify Protection

```bash
# Test 1: Try to deploy backdoored deployment (should FAIL)
kubectl apply -f ../attack-payloads/backdoored-deployment.yaml

# Test 2: Try to deploy cryptominer (should FAIL)
kubectl apply -f ../attack-payloads/malicious-pod.yaml

# Test 3: Try to deploy data exfil cronjob (should FAIL)
kubectl apply -f ../attack-payloads/data-exfil-cronjob.yaml

# All should be blocked by Kyverno!
```

## Monitoring and Alerts

### Watch for Policy Violations

```bash
# Kyverno policy violations
kubectl get policyreports -A

# Falco runtime detections
kubectl logs -f -n falco -l app=falco

# Network policy denials (requires CNI support)
# Check CNI logs (Calico, Cilium, etc.)
```

## Further Hardening

1. **Image Signing**: Use Cosign/Sigstore to sign all images
2. **SBOM Generation**: Create SBOMs with Syft/Trivy
3. **Vulnerability Scanning**: Scan images with Trivy/Grype
4. **Admission Controllers**: Add OPA Gatekeeper for custom policies
5. **Audit Logging**: Enable Kubernetes audit logs
6. **Secret Management**: Use external secret stores (Vault, AWS Secrets Manager)

## References

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [RBAC Best Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [Falco Rules](https://falco.org/docs/rules/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
