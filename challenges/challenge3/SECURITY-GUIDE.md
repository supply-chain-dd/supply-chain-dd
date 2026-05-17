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

## SBOM Signing, Provenance, and Conforma Verification

This section documents how the Challenge 3 pipeline handles SBOM attachment and
provenance, how it differs from the Konflux/RHTAP approach, and how Conforma
(Enterprise Contract) discovers SBOMs for policy evaluation.

### Our CTF Approach vs Konflux

Both approaches produce SLSA provenance via Tekton Chains. The difference is in
how additional artifacts (SBOM, scans) are attached and whether they are
independently signed.

| Aspect | CTF (this project) | Konflux |
|--------|-------------------|---------|
| SBOM generation | Trivy `--format spdx-json` | Syft SPDX JSON |
| SBOM attachment | `oras attach` as OCI referrer (`application/spdx+json`) | `cosign attach sbom --type spdx` |
| SBOM signing | Not independently signed — digest included as provenance subject via Chains type hint (`SBOM-ARTIFACT_URI`/`SBOM-ARTIFACT_DIGEST`) | `cosign attest --type spdxjson` creates a signed in-toto attestation with the SBOM as predicate |
| Signing method | N/A — Chains handles provenance signing with x509 keypair | Keyless: Fulcio short-lived certificate + projected ServiceAccount token + Rekor transparency log |
| Pipeline SBOM result | `SBOM-ARTIFACT_URI` + `SBOM-ARTIFACT_DIGEST` (Chains type hints → provenance subjects) | `SBOM_BLOB_URL` (blob content digest — not a Chains type hint) |
| Image signing | Tekton Chains auto-signs with cosign keypair (`signing-secrets` in `tekton-chains` namespace) | Tekton Chains auto-signs with keyless (Fulcio) |
| Vuln scan | Trivy `--scanners vuln` → `oras attach` → Chains type hints | Not part of standard Konflux build pipeline |
| Source VSA | Custom `verify-source-provenance` task → `oras attach` → Chains type hints | Not part of standard Konflux build pipeline |

**Key takeaway:** Our pipeline uses Tekton Chains type hinting to include SBOM,
vulnerability scan, secret scan, and Source VSA digests as **subjects** in the
SLSA provenance attestation. Konflux instead creates a separate signed SBOM
attestation via `cosign attest` and references it through `SBOM_BLOB_URL`.

### Why the Konflux Keyless Signing Approach Doesn't Fit KinD

Konflux's `cosign attest` uses **keyless signing** via Sigstore's Fulcio
certificate authority and projected ServiceAccount tokens. This requires
infrastructure that is not available in a local KinD cluster:

1. **Public Fulcio (`fulcio.sigstore.dev`) only accepts OIDC tokens from managed
   Kubernetes providers** — specifically EKS (AWS), GKE (Google Cloud), and AKS
   (Azure) — whose OIDC issuer URLs are publicly accessible and registered with
   Fulcio. KinD clusters have a local OIDC issuer
   (`https://kubernetes.default.svc.cluster.local`) that Fulcio cannot reach for
   token validation.

2. **Konflux does not use public Fulcio.** It deploys a **private Sigstore stack**
   (in-cluster Fulcio, Rekor, TUF) configured via a `cluster-config` ConfigMap in
   the `konflux-info` namespace. The ConfigMap contains:
   - `fulcioInternalUrl` / `fulcioExternalUrl`
   - `rekorInternalUrl` / `rekorExternalUrl`
   - `tufInternalUrl` / `tufExternalUrl`
   - `defaultOIDCIssuer`

3. **Our CTF Tekton Chains** is configured with `signers.x509.fulcio.enabled: false`
   and uses a local cosign keypair stored in the `signing-secrets` Secret in the
   `tekton-chains` namespace.

Despite these differences, our SBOM is still **discoverable by Conforma/EC** via
the OCI referrers API. Our `oras attach` uses the `application/spdx+json`
artifact type, which is in EC's recognized SBOM artifact types set (see
[SBOM_BLOB_URL and Conforma Policies](#sbom_blob_url-and-conforma-policies) below).

### How Local Sigstore + SPIFFE/SPIRE Could Enable Keyless Signing

To fully replicate the Konflux keyless signing approach in KinD, you would deploy
a local Sigstore stack using the
[sigstore/scaffolding](https://github.com/sigstore/scaffolding/blob/main/getting-started.md)
project.

#### Sigstore Scaffolding Deployment

Scaffolding deploys the full Sigstore stack in-cluster across four namespaces:

| Namespace | Component | In-cluster access |
|-----------|-----------|-------------------|
| `fulcio-system` | Fulcio (certificate authority) | `fulcio.fulcio-system.svc` |
| `rekor-system` | Rekor (transparency log) | `rekor.rekor-system.svc` |
| `ctlog-system` | TesseraCT (certificate transparency log) | `ctlog.ctlog-system.svc` |
| `tuf-system` | TUF root mirror (trust root distribution) | `tuf.tuf-system.svc` |

```bash
# Install via Helm
helm repo add sigstore https://sigstore.github.io/helm-charts
helm install sigstore-scaffold sigstore/scaffold

# Or use the release script
curl -Lo /tmp/setup-scaffolding-from-release.sh \
  https://github.com/sigstore/scaffolding/releases/download/v0.7.24/setup-scaffolding-from-release.sh
chmod u+x /tmp/setup-scaffolding-from-release.sh
/tmp/setup-scaffolding-from-release.sh
```

Scaffolding also includes a **test OIDC issuer** for keyless signing without
browser-based authentication:

```bash
ko apply -BRf ./testdata/config/gettoken
```

> **Warning:** The test OIDC issuer performs no authentication. Only install it on
> local test clusters.

#### Projected ServiceAccount Token Volume

Kubernetes projected ServiceAccount token volumes provide OIDC identity for
keyless signing. The projected token is consumed by cosign as `SIGSTORE_ID_TOKEN`:

```yaml
volumes:
  - name: oidc-token
    projected:
      sources:
        - serviceAccountToken:
            audience: sigstore
            expirationSeconds: 600
            path: oidc-token
```

```bash
# In the task step:
SIGSTORE_ID_TOKEN="$(cat /var/run/sigstore/cosign/oidc-token)"
export SIGSTORE_ID_TOKEN

cosign attest -y \
  --type spdxjson \
  --predicate sbom.json \
  --fulcio-url=http://fulcio.fulcio-system.svc:8080 \
  --rekor-url=http://rekor.rekor-system.svc:8080 \
  "$IMAGE_REF"
```

Before signing, you must initialize the TUF root so cosign trusts the local
Sigstore instance:

```bash
kubectl -n tuf-system get secrets tuf-root -ojsonpath='{.data.root}' | base64 -d > ./root.json
cosign initialize --mirror http://tuf.tuf-system.svc:8080 --root ./root.json
```

#### SPIFFE/SPIRE Integration

For production-grade workload identity (beyond test OIDC issuers), SPIFFE/SPIRE
can serve as the OIDC provider that Fulcio trusts:

- **SPIRE OIDC Discovery Provider** exposes a JWKS endpoint that Fulcio uses to
  validate workload identity tokens
- Fulcio configuration includes a `SPIFFETrustDomain` (e.g., `example.com`) and
  validates SPIFFE IDs from that domain
- Certificate SANs use the format:
  `https://kubernetes.io/namespaces/{namespace}/serviceaccounts/{sa-name}`
- Workflow: Pod identity → SPIRE SVID → OIDC token → Fulcio short-lived cert →
  cosign sign/attest

This enables true workload identity-based signing where the signing certificate
is tied to the Kubernetes ServiceAccount identity of the build task, not a
long-lived key.

**References:**
- [Sigstore Scaffolding Getting Started](https://github.com/sigstore/scaffolding/blob/main/getting-started.md)
- [Running Sigstore Locally](https://blog.sigstore.dev/a-guide-to-running-sigstore-locally-f312dfac0682/)
- [Zero-friction Keyless Signing with Kubernetes](https://www.chainguard.dev/unchained/zero-friction-keyless-signing-with-kubernetes)
- [OIDC Usage in Fulcio](https://docs.sigstore.dev/certificate_authority/oidc-in-fulcio/)
- [SPIRE OIDC Discovery Provider](https://github.com/spiffe/spire/blob/main/support/oidc-discovery-provider/README.md)
- [Tekton Chains Authentication](https://tekton.dev/docs/chains/authentication/)

### SBOM_BLOB_URL and Conforma Policies

Conforma (Enterprise Contract) uses the `ec validate image` command to verify
container images against supply chain security policies. SBOM verification is
handled by OPA/Rego policy rules in the
[enterprise-contract/ec-policies](https://github.com/enterprise-contract/ec-policies)
repository.

#### Three SBOM Discovery Methods

EC discovers SBOMs through three methods defined in `policy/lib/sbom/sbom.rego`.
If the same SBOM is found by multiple methods, duplicates are eliminated:

**1. SBOM Attestations** (`_sboms_from_input`)

Finds in-toto attestation statements with recognized SBOM predicate types:
- `https://spdx.dev/Document` (SPDX)
- `https://cyclonedx.org/bom` (CycloneDX)

These are created by `cosign attest --type spdxjson` (as Konflux does).

**2. SBOM_BLOB_URL from Provenance** (`_fetch_pipelinerun_sbom`)

Reads the SLSA provenance attestation generated by Tekton Chains, finds the
build task with a matching `IMAGE_DIGEST` result, and extracts the
`SBOM_BLOB_URL` task result. EC then fetches the SBOM blob content from the
OCI registry:

```rego
_fetch_pipelinerun_sbom contains sbom if {
    some attestation in lib.pipelinerun_attestations
    some task in tekton.build_tasks(attestation)

    expected_image_digest := image.parse(input.image.ref).digest
    image_digest := tekton.task_result(task, "IMAGE_DIGEST")
    expected_image_digest == image_digest

    blob_ref := tekton.task_result(task, "SBOM_BLOB_URL")
    blob := ec.oci.blob(blob_ref)
    sbom := json.unmarshal(blob)
}
```

The `SBOM_BLOB_URL` format is `registry/repo@sha256:<sha256sum-of-sbom-file>`.
The digest is the **blob content digest** computed locally with `sha256sum
sbom.json`, NOT an OCI manifest or referrer digest. This is what Konflux's
`buildah-oci-ta` task emits.

**3. OCI Referrers** (`_sboms_from_referrers`) — **used by our CTF pipeline**

Uses the OCI Referrers API to discover artifacts attached to the image with
recognized SBOM media types:

```rego
_sbom_artifact_types := {
    "application/spdx+json",
    "application/vnd.cyclonedx+json",
}

_sboms_from_referrers contains sbom if {
    some referrer in ec.oci.image_referrers(input.image.ref)
    referrer.artifactType in _sbom_artifact_types
    blob := ec.oci.blob(referrer.ref)
    sbom := json.unmarshal(blob)
}
```

Our Challenge 3 pipeline attaches the SBOM via `oras attach` with artifact type
`application/spdx+json`, which matches EC's `_sbom_artifact_types` set. This
means **our SBOM is discoverable by EC via OCI referrers** without needing
`SBOM_BLOB_URL` or `cosign attach sbom`.

#### Which Method to Use?

| Method | When to use | Our pipeline |
|--------|-------------|--------------|
| SBOM attestation | When SBOM is signed as an in-toto attestation via `cosign attest` | Not used |
| SBOM_BLOB_URL | When task emits blob URL result (Konflux pattern) | Not used |
| OCI referrers | When SBOM is attached via `oras attach` or `cosign attach sbom` with recognized artifact type | **Used** (`application/spdx+json`) |

All three methods feed into the same `sbom__found` policy rule, which checks
that at least one SBOM exists for the image being validated. Additional rules
(e.g., `sbom_spdx__valid`, `sbom_spdx__contains_packages`) then validate the
SBOM content.

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
