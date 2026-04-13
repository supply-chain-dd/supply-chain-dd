# Security Guide: Detecting and Preventing Base Image Poisoning

## Detection Methods

### 1. Kubescape - Image Vulnerability Scanning

**What it detects**: Known vulnerabilities, malware signatures, configuration issues

```bash
# Install Kubescape
kubectl apply -f https://raw.githubusercontent.com/kubescape/kubescape/master/deploy/kubescape.yaml

# Scan a specific image
kubescape scan image localhost:30000/recipe-api:latest

# Scan all images in cluster
kubescape scan cluster --include-namespaces production

# Look for:
# - HIGH/CRITICAL severity vulnerabilities
# - Unexpected packages or binaries
# - Non-standard entrypoints or commands
```

**Expected findings for poisoned image:**
- Suspicious binaries (`/usr/local/bin/backdoor.sh`)
- Modified entrypoint
- Unusual network capabilities

### 2. Guac - Software Bill of Materials (SBOM) Analysis

**What it detects**: Unexpected components, dependency anomalies, provenance violations

```bash
# Generate SBOM from image
syft localhost:30000/recipe-api:latest -o spdx-json > recipe-api-sbom.json

# Ingest into Guac for analysis
guacone collect files recipe-api-sbom.json

# Query for unexpected components
guacone query -s 'packages that were not in baseline image'

# Compare SBOMs between builds
diff baseline-sbom.json poisoned-sbom.json
```

**Red flags:**
- New packages not in official golang:1.25-alpine
- Modified file hashes
- Unknown provenance sources

### 3. Scorecard - Base Image Repository Security Assessment

**What it detects**: Repository security posture, maintenance practices

```bash
# Analyze the base image repository
scorecard --repo=github.com/docker-library/golang

# Check for:
# - Security policy existence
# - Signed releases
# - Vulnerability disclosure process
# - Dependency update practices
```

**Indicators of compromised repo:**
- Missing security.md
- No signed tags
- Irregular commit patterns
- New maintainers without history

### 4. AMPEL - Attestation Verification

**What it detects**: Build provenance violations, unsigned artifacts

```bash
# Verify SLSA attestations for base image
ampel verify --subject localhost:30000/golang:1.25-alpine \
  --policy policies/base-image-policy.yaml

# Expected policy checks:
# - Image has valid signature
# - Built from known source repository
# - Build environment meets SLSA L3 requirements
# - No unexpected modifications
```

**Create verification policy** (`policies/base-image-policy.yaml`):

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: base-image-verification
spec:
  subjects:
    - type: container-image
      pattern: "localhost:30000/golang:*"
  
  collectors:
    - type: sigstore
      trustRoot: https://fulcio.sigstore.dev
  
  checks:
    - name: image-signed
      description: Base image must be signed with Sigstore
      condition: attestation.signature.verified == true
      severity: CRITICAL
    
    - name: provenance-verified
      description: Build provenance must be valid
      condition: attestation.predicate.buildType == "https://slsa.dev/container-based-build/v0.1"
      severity: HIGH
    
    - name: trusted-builder
      description: Built by trusted CI/CD system
      condition: attestation.predicate.builder.id in ["github-actions", "tekton-chains"]
      severity: CRITICAL
```

### 5. Falco - Runtime Behavior Detection

**What it detects**: Suspicious runtime behavior, unexpected processes, network activity

```bash
# Deploy Falco with custom rules
kubectl apply -f https://raw.githubusercontent.com/falcosecurity/falco/master/deploy/kubernetes/falco-daemonset-configmap.yaml

# Create custom rule for backdoor detection
kubectl create configmap falco-rules --from-file=backdoor-detection.yaml -n falco
```

**Custom Falco Rule** (`backdoor-detection.yaml`):

```yaml
- rule: Suspicious Backdoor Execution
  desc: Detect execution of suspicious scripts that may be backdoors
  condition: >
    spawned_process and
    (proc.name in (nc, ncat, socat, curl, wget) or
     proc.cmdline contains "backdoor" or
     proc.cmdline contains "/tmp/." or
     fd.name contains ".malware")
  output: >
    Potential backdoor execution detected
    (user=%user.name command=%proc.cmdline container=%container.name image=%container.image.repository)
  priority: CRITICAL
  tags: [malware, backdoor, container]

- rule: Unexpected Network Connection from Container
  desc: Detect containers making connections to non-standard ports
  condition: >
    outbound and
    container and
    not fd.sport in (80, 443, 8080, 8443) and
    not fd.sip in (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
  output: >
    Unexpected outbound connection
    (connection=%fd.name port=%fd.sport ip=%fd.sip container=%container.name)
  priority: WARNING
  tags: [network, container, exfiltration]
```

**Monitor for alerts:**

```bash
kubectl logs -n falco -l app=falco -f | grep -E 'CRITICAL|backdoor'
```

### 6. Static Image Analysis

**Manual inspection techniques:**

```bash
# Extract and inspect image layers
podman save localhost:30000/recipe-api:latest -o recipe-api.tar
tar -xf recipe-api.tar
find . -name layer.tar | xargs -I {} tar -tvf {}

# Look for suspicious files
find . -name "*backdoor*" -o -name ".*malware*" -o -name "*.sh" | grep -v ".git"

# Check entrypoint modifications
podman inspect localhost:30000/recipe-api:latest | jq '.[].Config.Entrypoint'

# Compare with known-good image
diff <(podman inspect golang:1.23-alpine) <(podman inspect localhost:30000/golang:1.25-alpine)
```

## Prevention Techniques

### 1. Use Immutable Image Digests

**Never use tags, always use digests:**

```dockerfile
# ❌ BAD - Mutable tag
FROM localhost:30000/golang:1.25-alpine

# ✅ GOOD - Immutable digest
FROM localhost:30000/golang@sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890
```

**How to get digests:**

```bash
# Get digest of pulled image
podman inspect golang:1.23-alpine --format '{{.RepoDigests}}'

# Get digest from remote registry
skopeo inspect docker://localhost:30000/golang:1.25-alpine | jq -r '.Digest'
```

### 2. Image Signing with Sigstore/Cosign

**Sign images at build time:**

```bash
# Generate signing key (once)
cosign generate-key-pair

# Sign image after build
cosign sign --key cosign.key localhost:30000/recipe-api:latest

# Verify signature before use
cosign verify --key cosign.pub localhost:30000/recipe-api:latest
```

**Enforce signature verification in Kubernetes** (using Kyverno):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-signature
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "localhost:30000/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

### 3. SBOM Generation and Validation

**Generate SBOM at build time:**

```bash
# Using Syft
syft packages localhost:30000/recipe-api:latest -o spdx-json > sbom.json

# Using Docker buildx
docker buildx build --sbom=true -t localhost:30000/recipe-api:latest .
```

**Validate SBOM against baseline:**

```bash
# Create baseline from official image
syft packages golang:1.23-alpine -o json > baseline-sbom.json

# Compare current image SBOM
syft packages localhost:30000/golang:1.25-alpine -o json > current-sbom.json

# Find differences (should be empty for legitimate image)
jq -r '.artifacts[].name' current-sbom.json | sort > current-packages.txt
jq -r '.artifacts[].name' baseline-sbom.json | sort > baseline-packages.txt
diff baseline-packages.txt current-packages.txt
```

**Kyverno policy to require SBOM attestations:**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-sbom-attestation
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-sbom-exists
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "localhost:30000/*"
          attestations:
            - predicateType: https://spdx.dev/Document
              conditions:
                - all:
                    - key: "{{ creationInfo.created }}"
                      operator: NotEquals
                      value: ""
```

### 4. VEX (Vulnerability Exploitability eXchange)

**Use VEX to contextualize vulnerabilities:**

```bash
# Generate VEX document
cat > recipe-api.vex.json <<EOF
{
  "@context": "https://openvex.dev/ns",
  "@id": "localhost:30000/recipe-api:latest",
  "author": "Security Team",
  "timestamp": "2026-04-13T00:00:00Z",
  "statements": [
    {
      "vulnerability": "CVE-2024-XXXX",
      "products": ["localhost:30000/recipe-api:latest"],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path"
    }
  ]
}
EOF

# Attach VEX to image
cosign attest --key cosign.key --predicate recipe-api.vex.json localhost:30000/recipe-api:latest
```

**Query VEX documents:**

```bash
# Extract VEX attestation
cosign verify-attestation --key cosign.pub --type https://openvex.dev/ns localhost:30000/recipe-api:latest
```

### 5. Kyverno Image Validation Policies

**Comprehensive image security policy:**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: secure-base-images
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    # Rule 1: Require images from trusted registries only
    - name: trusted-registry-only
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Images must come from trusted registries"
        pattern:
          spec:
            containers:
              - image: "localhost:30000/*|docker.io/library/*|gcr.io/distroless/*"
    
    # Rule 2: Disallow mutable tags (latest, stable, etc)
    - name: disallow-mutable-tags
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Use image digests instead of tags"
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.containers[].image }}"
                operator: AnyNotIn
                value: "*@sha256:*"
    
    # Rule 3: Block images without signatures
    - name: require-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "localhost:30000/*"
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...
                      -----END PUBLIC KEY-----
```

**Apply the policy:**

```bash
kubectl apply -f security/kyverno-policies/secure-base-images.yaml

# Test policy (should block unsigned images)
kubectl run test --image=localhost:30000/recipe-api:latest
# Error: admission webhook denied the request: image signature verification failed
```

### 6. Network Policies - Egress Restriction

**Prevent malware from exfiltrating data:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-external-egress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: recipe-api
  policyTypes:
    - Egress
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    
    # Allow internal cluster communication
    - to:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 8080
    
    # Block all other egress (prevents exfiltration)
```

**Apply network policy:**

```bash
kubectl apply -f security/network-policies/deny-external-egress.yaml

# Verify policy
kubectl describe networkpolicy deny-external-egress -n production
```

### 7. Secure Tekton Pipeline Configuration

**Tekton Task with image verification:**

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build-with-verified-base
  namespace: ctf-challenge
spec:
  params:
    - name: base-image-digest
      type: string
      description: Immutable digest of base image
    - name: base-image-signature
      type: string
      description: Expected signature of base image
  
  steps:
    # Step 1: Verify base image signature
    - name: verify-base-image
      image: gcr.io/projectsigstore/cosign:latest
      script: |
        #!/bin/sh
        set -e
        echo "Verifying base image signature..."
        cosign verify --key /etc/cosign/cosign.pub \
          $(params.base-image-digest)
    
    # Step 2: Build application with verified base
    - name: build-image
      image: gcr.io/kaniko-project/executor:latest
      args:
        - --dockerfile=Dockerfile
        - --context=/workspace/source
        - --destination=localhost:30000/recipe-api:latest
        - --build-arg=BASE_IMAGE=$(params.base-image-digest)
      volumeMounts:
        - name: cosign-keys
          mountPath: /etc/cosign
          readOnly: true
  
  volumes:
    - name: cosign-keys
      secret:
        secretName: cosign-public-key
```

### 8. Runtime Monitoring with Falco

**Deploy Falco for runtime protection:**

```bash
# Install Falco
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set falco.rules_file[0]=/etc/falco/rules.d

# Deploy custom rules from security guide
kubectl apply -f security/falco-rules/backdoor-detection.yaml
```

## Verification

### Verify Prevention Controls

```bash
# 1. Verify Kyverno is enforcing policies
kubectl get clusterpolicy secure-base-images
kubectl describe clusterpolicy secure-base-images

# 2. Test unsigned image rejection
kubectl run test-unsigned --image=localhost:30000/golang:latest
# Expected: Error from admission webhook

# 3. Verify network policy blocks egress
kubectl exec -n production deploy/recipe-api -- curl https://evil.com
# Expected: Timeout or connection refused

# 4. Check Falco is running
kubectl get pods -n falco -l app=falco
kubectl logs -n falco -l app=falco | tail -20
```

### Security Audit Checklist

- [ ] All images use digests (not tags)
- [ ] Image signatures verified before deployment
- [ ] SBOM generated and validated for all builds
- [ ] VEX documents attached to images
- [ ] Kyverno policies enforced
- [ ] Network policies restrict egress
- [ ] Falco runtime monitoring active
- [ ] Regular image scanning with Kubescape
- [ ] Guac supply chain graph updated

## Remediation Steps

If base image poisoning is detected:

1. **Immediate Actions:**
   ```bash
   # Quarantine affected images
   kubectl scale deploy/recipe-api --replicas=0 -n production
   
   # Pull and analyze malicious image for forensics
   podman save localhost:30000/recipe-api:latest -o evidence.tar
   
   # Delete poisoned image from registry
   skopeo delete docker://localhost:30000/golang:1.25-alpine
   ```

2. **Investigation:**
   - Review registry access logs
   - Identify who pushed the poisoned image
   - Determine scope of impact (how many builds affected)
   - Check for data exfiltration in network logs

3. **Recovery:**
   ```bash
   # Re-pull official base image
   podman pull golang:1.23-alpine
   
   # Verify digest matches official
   skopeo inspect docker://docker.io/library/golang:1.23-alpine | jq .Digest
   
   # Push verified image to registry
   podman tag golang:1.23-alpine localhost:30000/golang:1.25-alpine
   podman push localhost:30000/golang:1.25-alpine
   
   # Rebuild all affected applications
   kubectl delete pipelinerun --all -n ctf-challenge
   kubectl create -f clean-rebuild-pipeline.yaml
   ```

4. **Post-Incident:**
   - Implement all prevention controls above
   - Rotate all credentials potentially exposed
   - Notify affected parties
   - Update incident response procedures

## References

- **Sigstore**: https://www.sigstore.dev/
- **SLSA Framework**: https://slsa.dev/
- **Kyverno Image Verification**: https://kyverno.io/docs/writing-policies/verify-images/
- **OpenVEX**: https://openvex.dev/
- **Syft SBOM Tool**: https://github.com/anchore/syft
- **Guac**: https://guac.sh/
- **Falco**: https://falco.org/
- **Kubescape**: https://www.armosec.io/kubescape/
