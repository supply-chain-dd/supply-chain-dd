# Supply Chain Security Tools Evaluation

This document evaluates whether modern supply chain security tools (SLSA provenance, SBOMs, source verification, AMPEL, Conforma, Image Signatures, Tekton Chains) can effectively detect and prevent the attacks demonstrated in this CTF.

## Evaluation Criteria

For each attack, we assess:
- **Effectiveness**: Can the tool prevent/detect this attack?
- **Coverage Gap**: What aspects of the attack remain unaddressed?
- **Implementation Complexity**: How difficult is it to deploy?
- **Real-world Applicability**: Is this practical for production use?

---

## Challenge 1: Pull Request Target (CI/CD Token Theft)

### Attack Summary
Malicious code in attacker's fork executes with victim's CI/CD permissions, steals Kubernetes secrets via ServiceAccount token, exfiltrates data.

### SLSA Provenance - ⚠️ LIMITED EFFECTIVENESS

**Can it help?**
- ✅ SLSA Level 3+ would require isolated build environments (preventing some token access)
- ✅ Provenance would document that code came from untrusted PR
- ❌ Does NOT prevent untrusted code execution in first place
- ❌ Provenance is generated AFTER attack already succeeded

**Gap**: SLSA focuses on build integrity, not runtime authorization. The attack exploits workflow design (`pull_request_target`), not build tampering.

**Recommendation**: SLSA provenance is **not sufficient** for this attack. Use GitHub Actions security scanning (Zizmor, Scorecard) instead.

### SBOMs - ❌ NOT APPLICABLE

**Why not?**
- Attack doesn't involve dependencies or package confusion
- Malicious payload is inline Go code, not a library
- SBOM would document the attack payload as legitimate source code

**Verdict**: SBOMs do not address this attack vector.

### Source Verification (Scorecard) - ✅ EFFECTIVE

**Can it help?**
- ✅ **Dangerous-Workflow** check detects `pull_request_target` misuse
- ✅ **Token-Permissions** check identifies excessive `secrets: inherit`
- ✅ Can be enforced in CI to block vulnerable workflows

**Example**:
```bash
scorecard --repo=github.com/victim/repo --checks=Dangerous-Workflow
# Score: 0/10
# Reason: pull_request_target with code checkout from untrusted ref
```

**Verdict**: Scorecard is **highly effective** for detection. Should be mandatory in CI.

### AMPEL - ⚠️ LIMITED EFFECTIVENESS

**Can it help?**
- ✅ Could verify that PipelineRuns have attestations from trusted sources
- ✅ Could enforce that PR-triggered runs are read-only (no secret access)
- ❌ Does not prevent workflow misconfiguration
- ⚠️ Requires Tekton Chains or similar to generate attestations

**Example Policy**:
```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
spec:
  checks:
    - name: pr-builds-readonly
      condition: |
        attestation.predicate.metadata.triggerType == "pull_request" &&
        attestation.predicate.serviceAccount != "default"
      severity: CRITICAL
```

**Verdict**: AMPEL can **enforce policies** on builds, but doesn't fix the root cause (workflow design).

### Conforma - ❌ NOT APPLICABLE

**Why not?**
- Conforma focuses on software compliance and policy enforcement
- This attack exploits CI/CD configuration, not artifact compliance
- No attestation exists yet (attack happens during build)

**Verdict**: Not the right tool for this attack.

### Image Signatures (Cosign/Sigstore) - ❌ NOT APPLICABLE

**Can it help?**
- ❌ Attack happens **during build**, before any image exists to sign
- ❌ Signatures verify artifact integrity, not build process security
- ❌ A signed image could still contain stolen secrets if built with compromised workflow
- ⚠️ Could enforce that only signed images from trusted builders are deployed, but doesn't prevent the theft

**Gap**: Image signatures operate at the wrong layer for this attack. The secret theft happens in the CI/CD runtime environment, not in the artifact itself.

**Scenario**: Even if you require signed images:
1. Attacker's PR triggers vulnerable workflow
2. Malicious code steals secrets during build
3. Secrets are exfiltrated before image is even created
4. Build completes, image gets signed normally
5. ✅ Signed image is deployed (signature is valid!)
6. ❌ But secrets were already stolen

**Verdict**: Image signatures do **not prevent or detect** this attack. The attack precedes image creation.

### Tekton Chains - ⚠️ LIMITED EFFECTIVENESS (forensics only)

**What is Tekton Chains?**
- Kubernetes controller that observes Tekton PipelineRuns/TaskRuns
- Automatically generates signed SLSA provenance attestations
- Records what happened during the build (materials, steps, results)
- Signs attestations using Sigstore (keyless or with keys)
- Stores attestations in OCI registries

**Can it help?**
- ❌ Does NOT prevent the attack from happening
- ❌ Attestation is generated AFTER secrets are already stolen
- ⚠️ Could document evidence of the attack for forensics
- ⚠️ Shows which PR/commit triggered the malicious build
- ✅ Can be used with AMPEL to enforce policies on future builds

**Gap**: Tekton Chains is a **recording mechanism**, not a prevention mechanism. It generates provenance after execution completes.

**Attack timeline**:
1. Attacker's PR triggers vulnerable pipeline
2. Malicious code executes, steals secrets (attack happens here ❌)
3. Secrets exfiltrated to attacker.com
4. PipelineRun completes
5. Tekton Chains generates SLSA provenance (too late ⏰)
6. Attestation documents what happened, including malicious steps

**How it helps (post-incident)**:

```bash
# After discovering the breach, use Chains attestation for forensics
cosign verify-attestation --type slsaprovenance \
  localhost:30000/victim-app:compromised-build

# Attestation reveals:
{
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildType": "https://tekton.dev/attestations/chains@v2",
    "invocation": {
      "configSource": {
        "uri": "git+https://github.com/attacker/fork.git",  # ⚠️ Red flag!
        "digest": {"sha1": "malicious-commit-sha"}
      }
    },
    "materials": [
      {
        "uri": "git+https://github.com/attacker/fork.git@refs/pull/1/head"  # ⚠️ PR from attacker!
      }
    ]
  }
}
```

**Preventive use with AMPEL**:

While Chains can't prevent the initial attack, it can prevent **future** attacks:

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: block-untrusted-pr-builds
spec:
  checks:
    - name: require-trusted-source
      condition: |
        attestation.predicateType == "https://slsa.dev/provenance/v1" &&
        attestation.predicate.materials[0].uri.startsWith("git+https://github.com/victim/official-repo")
      severity: CRITICAL
    
    - name: block-pr-trigger
      condition: |
        attestation.predicate.metadata.triggerType != "pull_request"
      severity: HIGH
```

**Value proposition**:
1. **Forensics**: Understand what happened after a breach
2. **Audit trail**: Immutable record of all builds
3. **Policy enforcement**: AMPEL can block deployments from suspicious sources
4. **Attribution**: Identify which PR/commit caused the issue

**Verdict**: Tekton Chains provides **valuable forensics and audit trail**, but does **not prevent** the attack. Use Scorecard/Zizmor for prevention.

### Kubescape - ⚠️ LIMITED EFFECTIVENESS

**Can it help?**
- ❌ Does NOT detect CI/CD workflow vulnerabilities
- ❌ Does NOT scan GitHub Actions or Tekton pipeline configurations
- ⚠️ Can detect excessive RBAC permissions on ServiceAccounts (post-deployment)
- ⚠️ Can identify pods with access to sensitive secrets (runtime)
- ✅ Can be integrated into pipelines to scan cluster state

**Gap**: Kubescape operates at the Kubernetes resource layer, not the CI/CD workflow layer. The attack exploits pipeline design (`pull_request_target`), which happens before Kubernetes resources are created.

**How it could help (partial)**:

```bash
# Scan cluster for excessive ServiceAccount permissions
kubescape scan framework nsa --include-namespaces ctf-challenge

# Would detect (after deployment):
# - ServiceAccount with cluster-admin binding
# - Pod with access to Kubernetes API
# - Excessive RBAC permissions
```

**Example control violations**:
- **C-0035**: Cluster-admin binding to ServiceAccount
- **C-0053**: Access to Kubernetes API server
- **C-0057**: Privileged container

**Verdict**: Kubescape can detect **post-deployment symptoms** but does NOT prevent the workflow misconfiguration itself. Use Scorecard/Zizmor for prevention.

### GUAC - ❌ NOT APPLICABLE

**Why not?**
- GUAC analyzes software supply chain metadata (SBOMs, provenance, vulnerabilities)
- This attack involves CI/CD workflow configuration, not artifact dependencies
- No supply chain graph to analyze (attack happens before build completes)
- Could document the incident after the fact, but doesn't prevent it

**What GUAC would show (post-incident)**:

```bash
# Query: What pipelines have access to production secrets?
guacone query "
  MATCH (pipeline:Pipeline)-[:HAS_ACCESS]->(secret:Secret)
  WHERE secret.environment = 'production'
  RETURN pipeline.name, secret.name
"
# Would show the vulnerable pipeline, but only after ingestion
```

**Verdict**: GUAC is the wrong tool for this attack vector. It operates on artifact metadata, not CI/CD configurations.

### Summary for Challenge 1

| Tool | Effectiveness | Primary Gap |
|------|---------------|-------------|
| SLSA Provenance | ⚠️ Limited | Doesn't prevent untrusted code execution |
| SBOMs | ❌ Not applicable | Attack uses inline code, not dependencies |
| Scorecard | ✅ Effective | Best detection tool for this attack |
| AMPEL | ⚠️ Limited | Post-hoc enforcement, not prevention |
| Conforma | ❌ Not applicable | Wrong problem domain |
| **Image Signatures** | ❌ Not applicable | Attack precedes image creation |
| **Tekton Chains** | ⚠️ Limited | Forensics only, not prevention |
| **Kubescape** | ⚠️ Limited | Detects symptoms, not root cause |
| **GUAC** | ❌ Not applicable | Wrong problem domain (artifacts vs workflows) |

**Recommended Stack**:
1. **Zizmor** or **Scorecard** in CI (blocks vulnerable workflows)
2. **Kyverno** to enforce ServiceAccount restrictions
3. **Network Policies** to prevent exfiltration
4. **Kubescape** for post-deployment validation

---

## Challenge 2: Leaked Secrets in Container Images

**NOTE**: Challenge 2 is missing a SECURITY-GUIDE.md file.

### Attack Summary
Secrets (.env files, API keys) embedded in container image layers, exposed to anyone with image access.

### SLSA Provenance - ⚠️ PARTIALLY EFFECTIVE

**Can it help?**
- ✅ SLSA Level 2+ requires hermetic builds (reduces secret leakage)
- ✅ Provenance documents build inputs (could flag unexpected .env files)
- ❌ Does NOT scan image contents for secrets
- ❌ Provenance only says "build was as documented", not "build is secure"

**Gap**: Provenance verifies build process, not artifact security.

### SBOMs - ⚠️ PARTIALLY EFFECTIVE

**Can it help?**
- ✅ SBOM generation tools (Syft, Trivy) scan image layers
- ⚠️ Standard SBOMs focus on packages, not arbitrary files
- ❌ Most SBOMs don't detect `.env` files as vulnerabilities

**Example**:
```bash
syft localhost:30000/recipe-api:latest -o json | jq '.files[] | select(.path | contains(".env"))'
# Would find .env files if configured properly
```

**Gap**: Need secret-specific scanning (Trivy, Kubescape), not just SBOM.

### Source Verification (Scorecard) - ❌ NOT APPLICABLE

**Why not?**
- Scorecard evaluates repository security, not build artifacts
- Doesn't scan container images
- Could catch .env files in Git (if using Secret-Scanning check)

**Verdict**: Wrong layer - use image scanners instead.

### AMPEL - ✅ EFFECTIVE (with proper policy)

**Can it help?**
- ✅ Can enforce that images have been scanned for secrets
- ✅ Can require attestations from Trivy/Kubescape before deployment
- ✅ Can block images without scan results

**Example Policy**:
```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
spec:
  checks:
    - name: no-leaked-secrets
      condition: |
        attestation.predicateType == "https://aquasecurity.github.io/trivy/scan/v1" &&
        attestation.predicate.secretFindings == []
      severity: CRITICAL
```

**Verdict**: AMPEL can **enforce secret scanning**, but requires integration with scanners.

### Conforma - ✅ EFFECTIVE (compliance enforcement)

**Can it help?**
- ✅ Can enforce that images meet security baselines (no secrets)
- ✅ Can require attestations from multiple scanners
- ✅ Policy-as-code for image compliance

**Example**:
```yaml
# Conforma policy
apiVersion: conforma.dev/v1alpha1
kind: Policy
metadata:
  name: no-secrets-in-images
spec:
  rules:
    - name: trivy-secret-scan
      attestations:
        - type: https://aquasecurity.github.io/trivy/scan/v1
          conditions:
            - path: predicate.results[].secrets
              operator: Empty
```

**Verdict**: Conforma is **highly effective** when combined with scanners.

### Image Signatures (Cosign/Sigstore) - ⚠️ LIMITED EFFECTIVENESS

**Can it help?**
- ✅ Verifies image hasn't been tampered with after signing
- ✅ Proves image came from trusted builder
- ❌ Does **NOT** scan image contents for secrets
- ❌ A properly signed image can still contain leaked secrets

**Gap**: Signatures verify **authenticity and integrity**, not **content security**.

**Scenario**:
1. Developer accidentally includes `.env` file in Dockerfile
2. Build runs, image contains secrets in layer
3. Image gets signed by trusted CI/CD system
4. ✅ Signature is valid (image is authentic)
5. ❌ But secrets are still leaked in image layers
6. Anyone who pulls the image can extract secrets from layers

**How it helps (partial)**:
- Ensures only images from authorized builders are deployed
- Can be combined with policy: "Only deploy signed images that also have secret-scan attestations"
- Prevents unsigned/tampered images, but doesn't detect secrets

**Example combined policy**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
spec:
  rules:
    - name: require-signature-and-scan
      verifyImages:
        - imageReferences: ["*"]
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...
                      -----END PUBLIC KEY-----
          attestations:
            - predicateType: https://aquasecurity.github.io/trivy/scan/v1
              conditions:
                - key: "{{ secretFindings }}"
                  operator: Equals
                  value: []
```

**Verdict**: Image signatures are **necessary but not sufficient**. Must be combined with secret scanning attestations.

### Tekton Chains - ✅ EFFECTIVE (when integrated with scanners)

**Can it help?**
- ✅ Generates SLSA provenance documenting build inputs
- ✅ Can integrate with Trivy/Kubescape for secret scanning
- ✅ Attestations can include scan results
- ✅ AMPEL can enforce that Chains attestations include clean secret scans
- ⚠️ Chains itself doesn't scan for secrets (needs integration)

**How it works**:

**Step 1: Configure Chains to run secret scanning**:
```yaml
# Tekton Pipeline with secret scanning
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-with-secret-scan
spec:
  tasks:
    - name: build-image
      taskRef:
        name: kaniko-build
      # ... build configuration
    
    - name: scan-for-secrets
      taskRef:
        name: trivy-secret-scan
      params:
        - name: image
          value: $(tasks.build-image.results.image-digest)
      runAfter:
        - build-image
```

**Step 2: Chains captures scan results in attestation**:

When the PipelineRun completes, Tekton Chains automatically:
1. Generates SLSA provenance
2. Includes TaskRun results (including scan results)
3. Signs the attestation
4. Stores it alongside the image

**Example attestation**:
```json
{
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildType": "https://tekton.dev/attestations/chains@v2",
    "buildConfig": {
      "tasks": [
        {
          "name": "scan-for-secrets",
          "results": [
            {
              "name": "secret-findings",
              "value": "FOUND: .env file in layer 3"  # ⚠️ Secret detected!
            },
            {
              "name": "scan-status",
              "value": "FAILED"
            }
          ]
        }
      ]
    }
  }
}
```

**Step 3: AMPEL enforces clean scan**:
```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: require-clean-secret-scan
spec:
  checks:
    - name: tekton-chains-secret-scan
      condition: |
        attestation.predicateType == "https://slsa.dev/provenance/v1" &&
        attestation.predicate.buildConfig.tasks
          .filter(t => t.name == "scan-for-secrets")[0]
          .results
          .filter(r => r.name == "scan-status")[0]
          .value == "PASSED"
      severity: CRITICAL
      message: "Image failed secret scanning - deployment blocked"
```

**Real-world workflow**:
```bash
# 1. Developer pushes code with .env file (accidentally)
# 2. Tekton Pipeline runs:
#    - Builds image
#    - Scans image with Trivy
#    - Trivy finds .env file in layer
#    - TaskRun completes with FAILED status
# 3. Tekton Chains generates attestation documenting the failure
# 4. Developer tries to deploy:
kubectl apply -f deployment.yaml
# 5. AMPEL checks Chains attestation
# 6. Sees scan-status: FAILED
# 7. Blocks deployment:
Error: admission webhook denied: image failed secret scan (see attestation)
```

**Advantages over manual scanning**:
1. **Automatic**: No manual steps, Chains handles it
2. **Immutable**: Attestation can't be tampered with (signed)
3. **Verifiable**: Anyone can verify the scan happened and results
4. **Audit trail**: All builds have scan records

**Integration architecture**:
```
[Tekton Pipeline] → [Build Task] → [Secret Scan Task (Trivy)] → [Complete]
                                           ↓
                                    [Tekton Chains Observer]
                                           ↓
                              [Generate SLSA Provenance + Scan Results]
                                           ↓
                                   [Sign with Sigstore]
                                           ↓
                              [Store attestation with image]
                                           ↓
                        [Deploy time: AMPEL verifies attestation]
```

**Challenges**:
- Requires Tekton-native scanning tasks
- Need to configure Chains to capture specific results
- AMPEL policy must know Chains attestation structure

**Verdict**: Tekton Chains is **highly effective** when integrated with secret scanning tasks. Provides automatic, verifiable proof that images were scanned.

### Kubescape - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ **Scans container images for secrets and sensitive files**
- ✅ Detects `.env` files, API keys, tokens in image layers
- ✅ Can be integrated into Tekton pipelines as scanning task
- ✅ Provides risk scores for images
- ✅ Supports multiple scanning modes (image, cluster, manifest)
- ✅ Can block deployment of images with secrets via admission control

**What is Kubescape?**
- Kubernetes security scanner from ARMO
- Scans images, manifests, and running workloads
- Checks against NSA/CISA hardening guides, CIS benchmarks
- Detects misconfigurations, vulnerabilities, and secrets

**Example Usage**:

```bash
# Scan image for secrets before deployment
kubescape scan image localhost:30000/recipe-api:latest \
  --format json --output results.json

# Check for secrets in layers
jq '.results[] | select(.resourceID | contains("Secret")) | .controls[]' results.json

# Example findings:
{
  "controlID": "C-0012",
  "name": "Applications credentials in configuration files",
  "severity": "CRITICAL",
  "failedResources": [
    {
      "resourceID": "/app/.env.production",
      "reason": "Environment file with credentials found in image layer"
    }
  ]
}
```

**Integration with Tekton**:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: kubescape-image-scan
spec:
  params:
    - name: image
      type: string
  steps:
    - name: scan
      image: quay.io/armosec/kubescape:latest
      script: |
        #!/bin/sh
        kubescape scan image $(params.image) \
          --threshold 0 \
          --fail-on-severity CRITICAL \
          --format json \
          --output /workspace/scan-results.json || exit 1
```

**AMPEL policy for Kubescape attestations**:

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
spec:
  checks:
    - name: kubescape-secret-scan-passed
      condition: |
        attestation.predicateType == "https://kubescape.io/scan/v1" &&
        attestation.predicate.riskScore < 50 &&
        !attestation.predicate.controls.some(c => c.controlID == "C-0012" && c.status == "failed")
      severity: CRITICAL
      message: "Image failed Kubescape secret scanning"
```

**Advantages**:
- **Comprehensive**: Scans for secrets, vulnerabilities, and misconfigurations
- **Risk scoring**: Provides actionable risk assessment
- **Kubernetes-native**: Designed specifically for K8s environments
- **Framework support**: NSA, MITRE, CIS, SOC2

**Verdict**: Kubescape is **HIGHLY EFFECTIVE** for detecting leaked secrets in images. Should be integrated into build pipelines.

### GUAC - ⚠️ PARTIALLY EFFECTIVE (supply chain context)

**Can it help?**
- ⚠️ Does NOT scan images for secrets directly
- ✅ Can track which images contain which packages/files (via SBOM ingestion)
- ✅ Can identify affected deployments if a secret is leaked
- ✅ Provides supply chain graph to understand blast radius
- ✅ Can answer questions like "where is this vulnerable image deployed?"

**What is GUAC?**
- Graph for Understanding Artifact Composition
- Aggregates supply chain metadata (SBOMs, provenance, vulnerabilities)
- Builds queryable knowledge graph
- Helps understand dependencies and relationships

**How GUAC helps (indirectly)**:

```bash
# 1. Ingest SBOM that includes .env file
guacone collect files sbom://recipe-api-sbom.json

# 2. Query: Which images contain .env files?
guacone query "
  MATCH (image:Package)-[:CONTAINS]->(file:File)
  WHERE file.path =~ '.*\\.env.*'
  RETURN image.name, image.version, file.path
"

# Output:
| image.name  | image.version | file.path           |
|-------------|---------------|---------------------|
| recipe-api  | v1.0.0        | /app/.env.production |
| recipe-api  | v1.1.0        | /app/.env.production |

# 3. Query: Where are these images deployed?
guacone query "
  MATCH (deployment:Deployment)-[:USES]->(image:Package)
  WHERE image.name = 'recipe-api' AND image.version IN ['v1.0.0', 'v1.1.0']
  RETURN deployment.cluster, deployment.namespace, deployment.name
"

# Output shows blast radius:
| cluster     | namespace | deployment  |
|-------------|-----------|-------------|
| production  | default   | recipe-api  |
| staging     | default   | recipe-api  |
```

**Value proposition**:
1. **Incident response**: "Which environments have the leaked secret?"
2. **Blast radius**: "What else depends on this vulnerable image?"
3. **Remediation tracking**: "Have all affected deployments been updated?"
4. **Supply chain visibility**: "Where did this image come from?"

**Example incident response workflow**:

```bash
# Scenario: .env file leaked in recipe-api:v1.0.0

# 1. Find all instances
guacone query "
  MATCH path = (deployment)-[:USES*]->(image:Package {name: 'recipe-api', version: 'v1.0.0'})
  RETURN path
"

# 2. Identify dependencies
guacone query "
  MATCH (service:Package)-[:DEPENDS_ON]->(recipe:Package {name: 'recipe-api'})
  RETURN service.name, service.version
"
# Shows which services might have received the leaked secret

# 3. Verify cleanup
guacone query "
  MATCH (deployment:Deployment)-[:USES]->(image:Package)
  WHERE image.name = 'recipe-api'
  RETURN image.version, count(deployment) as deployment_count
"
# Ensure no deployments still use the vulnerable version
```

**Limitations**:
- Requires SBOM/provenance ingestion (doesn't scan itself)
- Needs integration with scanners (Trivy/Kubescape) for secret detection
- Post-incident tool, not prevention

**Verdict**: GUAC provides **valuable supply chain context** after secrets are discovered, but does NOT detect secrets itself. Use with Trivy/Kubescape for scanning.

### Summary for Challenge 2

| Tool | Effectiveness | Primary Gap |
|------|---------------|-------------|
| SLSA Provenance | ⚠️ Partial | Documents build, doesn't scan for secrets |
| SBOMs | ⚠️ Partial | Need secret-specific SBOM tooling |
| Scorecard | ❌ Not applicable | Wrong layer (repo vs image) |
| AMPEL | ✅ Effective | Requires integration with scanners |
| Conforma | ✅ Effective | Strong compliance enforcement |
| **Image Signatures** | ⚠️ Limited | Verifies authenticity, not content security |
| **Tekton Chains** | ✅ Effective | Excellent when integrated with scanning tasks |
| **Kubescape** | ✅ Highly effective | **PRIMARY SCANNING TOOL** for secrets in images |
| **GUAC** | ⚠️ Partial | Supply chain context, not detection |

**Recommended Stack**:
1. **Trivy** or **Kubescape** for secret scanning (must-have)
2. **AMPEL** or **Conforma** to enforce scan attestations
3. **Kyverno** to block unscanned images
4. **Git pre-commit hooks** to prevent secrets in commits
5. **GUAC** for incident response and blast radius analysis

---

## Challenge 3: Base Image Poisoning

### Attack Summary
Attacker pushes malicious base image (e.g., `golang:1.25-alpine`) with backdoor, victim builds on it unknowingly.

### SLSA Provenance - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ SLSA Level 3+ requires build provenance with source repository
- ✅ Can verify base image came from official Docker/Google repos
- ✅ Can detect if base image was built from unknown source
- ✅ Provenance attestations prevent tag swapping

**Example Verification**:
```bash
# Verify golang base image provenance
cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp=".*github.com/docker-library/golang.*" \
  docker.io/library/golang:1.23-alpine
```

**Verdict**: SLSA provenance is **critical** for this attack. MUST verify base image provenance.

### SBOMs - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ Compare SBOM of pulled image vs official image
- ✅ Detect unexpected packages (backdoor binaries)
- ✅ Guac can graph supply chain and detect anomalies
- ✅ VEX can document known vulnerabilities

**Example**:
```bash
# Compare SBOMs
syft golang:1.23-alpine -o json > official.json
syft localhost:30000/golang:1.25-alpine -o json > poisoned.json
diff <(jq -r '.artifacts[].name' official.json | sort) \
     <(jq -r '.artifacts[].name' poisoned.json | sort)
# Output: unexpected packages found
```

**Verdict**: SBOMs are **essential** for detecting poisoned images.

### Source Verification (Scorecard) - ✅ EFFECTIVE

**Can it help?**
- ✅ Verify base image repository has security policy
- ✅ Check for signed releases
- ✅ Verify maintainer reputation
- ✅ Detect repository compromise indicators

**Example**:
```bash
scorecard --repo=github.com/docker-library/golang
# Check: Signed-Releases, Security-Policy, Maintained
```

**Verdict**: Scorecard provides **repository trust verification**. Good first layer.

### AMPEL - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ Enforce that base images have valid SLSA provenance
- ✅ Require signatures from trusted builders
- ✅ Verify build environment meets security standards
- ✅ Block unsigned or unverified base images

**Example Policy** (from current SECURITY-GUIDE.md):
```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
spec:
  checks:
    - name: trusted-builder
      condition: attestation.predicate.builder.id in ["github-actions", "tekton-chains"]
      severity: CRITICAL
```

**Verdict**: AMPEL is **perfectly suited** for this attack. Should be mandatory.

### Conforma - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ Enforce compliance policies for all base images
- ✅ Require multiple attestations (SLSA + SBOM + signature)
- ✅ Block non-compliant images at admission time
- ✅ Integrate with Kyverno/OPA for enforcement

**Example**:
```yaml
apiVersion: conforma.dev/v1alpha1
kind: Policy
metadata:
  name: base-image-compliance
spec:
  rules:
    - name: require-provenance
      attestations:
        - type: https://slsa.dev/provenance/v1
          conditions:
            - path: predicate.builder.id
              operator: In
              values: ["https://github.com/docker-library"]
    - name: require-sbom
      attestations:
        - type: https://spdx.dev/Document
```

**Verdict**: Conforma provides **comprehensive compliance enforcement**. Ideal for this attack.

### Image Signatures (Cosign/Sigstore) - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ Verify base image is signed by official maintainer (Docker, Google)
- ✅ Detect unsigned or maliciously-signed images
- ✅ Prevent tag-swapping attacks (digest pinning)
- ✅ Enforce signature verification before using base image

**This is the PRIMARY use case for image signatures!**

**How it prevents the attack**:

1. **Official base images are signed**:
```bash
# Docker official images are signed
cosign verify --certificate-identity-regexp=".*docker.com.*" \
  docker.io/library/golang:1.23-alpine
```

2. **Poisoned images lack valid signatures**:
```bash
# Attacker's poisoned image
cosign verify localhost:30000/golang:1.25-alpine
# Error: no matching signatures
```

3. **Enforce signature verification in build**:
```dockerfile
# Dockerfile with signature verification
FROM docker.io/library/golang:1.23-alpine@sha256:abc123...
# Policy requires: image must have valid signature from docker.io
```

4. **Kyverno policy blocks unsigned base images**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-base-image-signatures
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-golang-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "docker.io/library/golang:*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/docker-library/golang"
                    issuer: "https://token.actions.githubusercontent.com"
```

**Real-world implementation**:

```bash
# In Tekton build task
steps:
  - name: verify-base-image
    image: gcr.io/projectsigstore/cosign:latest
    script: |
      #!/bin/sh
      set -e
      
      BASE_IMAGE="docker.io/library/golang:1.23-alpine"
      
      # Verify signature exists
      cosign verify \
        --certificate-identity-regexp=".*docker-library.*" \
        --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
        ${BASE_IMAGE}
      
      # Verify SLSA provenance
      cosign verify-attestation \
        --type slsaprovenance \
        --certificate-identity-regexp=".*docker-library.*" \
        ${BASE_IMAGE}
      
      echo "✅ Base image signature verified"
  
  - name: build-app
    image: gcr.io/kaniko-project/executor:latest
    # Build only proceeds if signature verification passed
```

**Defense-in-depth approach**:

1. **Signature verification** (authenticity)
2. **Digest pinning** (immutability)
3. **SBOM comparison** (content verification)
4. **SLSA provenance** (builder verification)

**Attack prevented**:
- ❌ Attacker cannot push poisoned image to Docker Hub (no Docker signing key)
- ❌ Attacker cannot sign image with fake docker.io identity (Sigstore prevents this)
- ❌ If attacker compromises local registry, signature verification fails
- ✅ Only legitimate, signed base images are used

**Verdict**: Image signatures are **CRITICAL** for preventing base image poisoning. This is their most important use case.

### Tekton Chains - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ **Automatically documents which base image was used** (digest)
- ✅ Records base image in SLSA provenance materials
- ✅ Detects if base image changed between builds
- ✅ AMPEL can enforce policies on base image provenance
- ✅ Provides audit trail of all base images used

**This is an EXCELLENT use case for Tekton Chains!**

**How it prevents the attack**:

**Step 1: Chains captures base image in provenance**:

When a Tekton PipelineRun builds an application, Chains automatically records the base image:

```json
{
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildType": "https://tekton.dev/attestations/chains@v2",
    "materials": [
      {
        "uri": "docker://docker.io/library/golang",
        "digest": {
          "sha256": "abc123..."  # Exact base image used
        }
      },
      {
        "uri": "git+https://github.com/victim/app.git",
        "digest": {"sha1": "def456..."}
      }
    ],
    "buildConfig": {
      "steps": [
        {
          "name": "build",
          "environment": {
            "BASE_IMAGE": "docker.io/library/golang@sha256:abc123..."
          }
        }
      ]
    }
  }
}
```

**Step 2: AMPEL policy requires trusted base images**:

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: verify-base-image-provenance
spec:
  checks:
    - name: base-image-from-official-registry
      description: Base image must come from Docker Hub official images
      condition: |
        attestation.predicateType == "https://slsa.dev/provenance/v1" &&
        attestation.predicate.materials
          .filter(m => m.uri.startsWith("docker://"))[0]
          .uri.startsWith("docker://docker.io/library/") 
      severity: CRITICAL
    
    - name: base-image-has-digest
      description: Base image must be pinned by digest
      condition: |
        attestation.predicate.materials
          .filter(m => m.uri.startsWith("docker://"))[0]
          .digest.sha256 != ""
      severity: CRITICAL
    
    - name: base-image-not-from-attacker-registry
      description: Prevent poisoned images from local registry
      condition: |
        !attestation.predicate.materials
          .some(m => m.uri.startsWith("docker://localhost:30000/"))
      severity: CRITICAL
      message: "Base image from untrusted local registry - possible poisoning attack"
```

**Attack scenario**:

**Without Tekton Chains**:
```bash
# Attacker pushes poisoned image
podman push localhost:30000/golang:1.25-alpine

# Developer builds (unknowingly using poisoned image)
FROM localhost:30000/golang:1.25-alpine  # ❌ No verification

# Deploy - no attestation exists
kubectl apply -f deployment.yaml  # ✅ Deploys with backdoor
```

**With Tekton Chains + AMPEL**:
```bash
# Attacker pushes poisoned image
podman push localhost:30000/golang:1.25-alpine

# Tekton Pipeline builds
# Chains generates provenance showing:
# materials[0].uri = "docker://localhost:30000/golang:1.25-alpine"

# Developer tries to deploy
kubectl apply -f deployment.yaml

# AMPEL checks Chains attestation
# Sees base image from "localhost:30000" (not docker.io)
# ❌ BLOCKS deployment:
Error: admission webhook denied: 
  Base image from untrusted local registry - possible poisoning attack
  Expected: docker.io/library/*
  Found: localhost:30000/golang:1.25-alpine
```

**Anomaly detection**:

Chains also enables detecting **changes** in base images:

```bash
# Compare attestations across builds
cosign verify-attestation --type slsaprovenance \
  localhost:30000/app:v1.0 | jq -r '.predicate.materials[] | select(.uri | startswith("docker://"))'

# Output for legitimate build:
{
  "uri": "docker://docker.io/library/golang",
  "digest": {"sha256": "abc123..."}  # Official golang image
}

# Output for poisoned build:
{
  "uri": "docker://localhost:30000/golang",  # ⚠️ DIFFERENT REGISTRY!
  "digest": {"sha256": "xyz789..."}  # ⚠️ DIFFERENT DIGEST!
}

# Alert: Base image changed unexpectedly!
```

**Integration with Guac**:

Tekton Chains attestations can feed into Guac for supply chain graph analysis:

```bash
# Ingest Chains attestations into Guac
guacone collect image localhost:30000/app:v1.0

# Query: What base images are used in production?
guacone query "
  MATCH (app:Package)-[:BUILT_FROM]->(base:Package)
  WHERE app.name = 'app'
  RETURN base.name, base.version, base.digest
"

# Output shows if poisoned image is being used:
| base.name | base.version | base.digest |
|-----------|--------------|-------------|
| golang    | 1.25-alpine  | sha256:xyz789 (⚠️ not official!) |
```

**Real-world workflow**:

```yaml
# Tekton Pipeline with base image verification
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: secure-build-pipeline
spec:
  tasks:
    # Task 1: Verify base image signature BEFORE building
    - name: verify-base-image-signature
      taskRef:
        name: cosign-verify-image
      params:
        - name: image
          value: "docker.io/library/golang:1.23-alpine"
        - name: expected-identity
          value: "https://github.com/docker-library/golang"
    
    # Task 2: Build application (only runs if verification passed)
    - name: build-app
      taskRef:
        name: kaniko-build
      runAfter:
        - verify-base-image-signature
      params:
        - name: image
          value: "localhost:30000/app:latest"

# After PipelineRun completes:
# 1. Tekton Chains automatically generates attestation
# 2. Attestation includes verified base image digest
# 3. AMPEL enforces policy before deployment
# 4. Only applications with verified base images can deploy
```

**Advantages**:
1. **Automatic**: No manual provenance generation
2. **Tamper-proof**: Attestations are signed
3. **Auditable**: Every build has base image recorded
4. **Policy-enforceable**: AMPEL can block bad base images
5. **Anomaly detection**: Detect unexpected base image changes

**Verdict**: Tekton Chains is **HIGHLY EFFECTIVE** for preventing base image poisoning. It provides automatic, verifiable documentation of which base images were used, enabling policy enforcement.

### Kubescape - ✅ HIGHLY EFFECTIVE (detection)

**Can it help?**
- ✅ **Scans base images for unexpected packages/binaries**
- ✅ Detects vulnerabilities in base images before use
- ✅ Can compare images against security baselines
- ✅ Identifies malicious or suspicious files
- ✅ Provides compliance scoring (CIS, NSA guidelines)
- ✅ Can be integrated into build pipelines to verify base images

**How Kubescape detects poisoned images**:

```bash
# 1. Scan the suspicious base image
kubescape scan image localhost:30000/golang:1.25-alpine \
  --format json --output poisoned-scan.json

# 2. Scan the official base image for comparison
kubescape scan image docker.io/library/golang:1.23-alpine \
  --format json --output official-scan.json

# 3. Compare security postures
diff <(jq '.results[].controls[]' official-scan.json | sort) \
     <(jq '.results[].controls[]' poisoned-scan.json | sort)

# Expected findings for poisoned image:
{
  "controlID": "C-0016",
  "name": "Allow privilege escalation",
  "severity": "CRITICAL",
  "failedResources": ["/malicious-binary"]
},
{
  "controlID": "C-0074",
  "name": "Malicious content in image",
  "severity": "CRITICAL",
  "failedResources": ["/usr/local/bin/backdoor"]
}
```

**Prevention workflow in Tekton**:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: secure-build-with-base-image-verification
spec:
  tasks:
    # Task 1: Scan base image before use
    - name: verify-base-image-security
      taskRef:
        name: kubescape-scan-base-image
      params:
        - name: base-image
          value: "docker.io/library/golang:1.23-alpine"
        - name: max-risk-score
          value: "50"  # Fail if risk score > 50
    
    # Task 2: Build only if base image is clean
    - name: build-application
      taskRef:
        name: kaniko-build
      runAfter:
        - verify-base-image-security
```

**Detection capabilities**:
- **Unexpected binaries**: Detects files not in official image
- **Privilege escalation**: Identifies setuid/setgid binaries
- **Compliance violations**: CIS benchmark failures
- **CVE scanning**: Known vulnerabilities in packages
- **Risk scoring**: Overall security posture assessment

**Example Kubescape TaskRun**:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: kubescape-verify-base-image
spec:
  params:
    - name: base-image
      type: string
    - name: expected-risk-score
      type: string
      default: "30"
  steps:
    - name: scan-base-image
      image: quay.io/armosec/kubescape:latest
      script: |
        #!/bin/sh
        set -e
        
        # Scan base image
        kubescape scan image $(params.base-image) \
          --format json \
          --output /tmp/scan.json
        
        # Extract risk score
        RISK_SCORE=$(jq '.summaryDetails.riskScore' /tmp/scan.json)
        
        echo "Base image risk score: $RISK_SCORE"
        
        # Fail if risk score exceeds threshold
        if [ "$RISK_SCORE" -gt "$(params.expected-risk-score)" ]; then
          echo "❌ Base image failed security scan"
          echo "Risk score $RISK_SCORE exceeds threshold $(params.expected-risk-score)"
          exit 1
        fi
        
        echo "✅ Base image passed security scan"
```

**Limitations**:
- Does NOT verify provenance (use Cosign/Chains for that)
- Does NOT check image signatures (use Cosign)
- Scans content, not supply chain authenticity
- Need baseline image for comparison

**Verdict**: Kubescape is **HIGHLY EFFECTIVE** for detecting poisoned base images by scanning their contents. Must be combined with signature verification.

### GUAC - ✅ HIGHLY EFFECTIVE (supply chain analysis)

**Can it help?**
- ✅ **PRIMARY USE CASE**: Supply chain graph analysis
- ✅ Tracks provenance of base images (where did they come from?)
- ✅ Identifies anomalies in supply chain (unexpected sources)
- ✅ Queries dependencies and relationships
- ✅ Detects when base images deviate from known-good sources
- ✅ Provides visibility into "who built what and when"

**What is GUAC's role in base image security?**

GUAC builds a knowledge graph from:
- SBOMs (what's in the image)
- SLSA provenance (how it was built)
- Vulnerability data (known issues)
- Relationships (what depends on what)

**How GUAC prevents/detects this attack**:

**Step 1: Ingest metadata for official golang image**:

```bash
# Ingest official golang image with provenance
guacone collect image docker.io/library/golang:1.23-alpine

# GUAC creates graph nodes:
{
  "Package": {
    "name": "golang",
    "version": "1.23-alpine",
    "repository": "docker.io/library"
  },
  "Builder": {
    "id": "https://github.com/docker-library/golang",
    "verified": true
  },
  "Source": {
    "repository": "https://github.com/docker-library/golang",
    "commit": "abc123..."
  }
}
```

**Step 2: Query for base image provenance**:

```bash
# Query: Where did this base image come from?
guacone query "
  MATCH (image:Package {name: 'golang', version: '1.25-alpine'})
        -[:BUILT_BY]->(builder:Builder)
  RETURN image.repository, builder.id, builder.verified
"

# For POISONED image:
| image.repository    | builder.id                  | builder.verified |
|---------------------|-----------------------------|------------------|
| localhost:30000     | unknown                     | false            |

# For OFFICIAL image:
| image.repository    | builder.id                                    | builder.verified |
|---------------------|-----------------------------------------------|------------------|
| docker.io/library   | https://github.com/docker-library/golang      | true             |
```

**Step 3: Detect anomalies**:

```bash
# Query: Find all base images NOT from official repositories
guacone query "
  MATCH (app:Package)-[:BUILT_FROM]->(base:Package)
  WHERE NOT base.repository IN ['docker.io/library', 'gcr.io/distroless']
  RETURN app.name, base.name, base.repository, base.version
"

# Output (detects attack):
| app.name   | base.name | base.repository    | base.version  |
|------------|-----------|-------------------|---------------|
| recipe-api | golang    | localhost:30000   | 1.25-alpine   | ⚠️ SUSPICIOUS!
```

**Step 4: Blast radius analysis**:

```bash
# Query: What applications use this poisoned base image?
guacone query "
  MATCH (app:Package)-[:BUILT_FROM]->(base:Package {repository: 'localhost:30000'})
  RETURN app.name, app.version, base.name
"

# Shows all affected applications:
| app.name      | app.version | base.name |
|---------------|-------------|-----------|
| recipe-api    | v1.0.0      | golang    |
| recipe-api    | v1.1.0      | golang    |
| auth-service  | v2.0.0      | golang    |
```

**Step 5: Remediation tracking**:

```bash
# Query: Have we fixed all instances?
guacone query "
  MATCH (deployment:Deployment)-[:USES]->(app:Package)
        -[:BUILT_FROM]->(base:Package)
  WHERE base.repository = 'localhost:30000'
  RETURN deployment.cluster, deployment.namespace, app.name
"

# If empty: All poisoned images removed ✅
```

**Integration with other tools**:

```bash
# GUAC ingests data from:
# 1. Tekton Chains (SLSA provenance)
guacone collect slsa attestation://chains-attestation.json

# 2. SBOMs (Syft/Trivy)
guacone collect files sbom://recipe-api-sbom.json

# 3. Vulnerability scanners
guacone collect guesser vulns://cve-data.json

# Then query the integrated graph
guacone query "
  MATCH (app:Package)-[:BUILT_FROM]->(base:Package)
        -[:HAS_VULN]->(vuln:CVE)
  WHERE vuln.severity = 'CRITICAL'
  RETURN app.name, base.name, vuln.id
"
```

**Policy enforcement with GUAC**:

```yaml
# AMPEL policy using GUAC data
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: verify-base-image-source-with-guac
spec:
  checks:
    - name: base-image-from-trusted-source
      description: Verify base image comes from official repository
      condition: |
        # Query GUAC for base image provenance
        guac_result = guac.query("
          MATCH (app:Package {digest: attestation.subject.digest})
                -[:BUILT_FROM]->(base:Package)
                -[:BUILT_BY]->(builder:Builder)
          RETURN base.repository, builder.verified
        ")
        
        # Require official repository
        guac_result[0].repository == "docker.io/library" &&
        guac_result[0].builder_verified == true
      severity: CRITICAL
```

**Real-world detection scenario**:

```
[Attacker pushes poisoned golang:1.25-alpine to localhost:30000]
         ↓
[Developer builds recipe-api using poisoned base]
         ↓
[Tekton Chains generates provenance including base image digest]
         ↓
[GUAC ingests provenance]
         ↓
[GUAC builds graph: recipe-api → BUILT_FROM → golang:1.25 @ localhost:30000]
         ↓
[Security team queries GUAC]
guacone query "MATCH (app)-[:BUILT_FROM]->(base) WHERE base.repository != 'docker.io/library' RETURN app, base"
         ↓
[🚨 ALERT: recipe-api built from untrusted base image!]
```

**Advantages of GUAC**:
1. **Supply chain visibility**: "Where did this come from?"
2. **Anomaly detection**: "Is this image from expected source?"
3. **Blast radius**: "What else is affected?"
4. **Historical analysis**: "When did this change?"
5. **Policy enforcement**: Integration with AMPEL/Conforma
6. **Cross-tool correlation**: Combines SBOMs, provenance, vulns

**Limitations**:
- Requires metadata ingestion (provenance, SBOMs)
- Does NOT scan images itself (use Trivy/Kubescape)
- Does NOT verify signatures (use Cosign)
- Post-build analysis (not real-time prevention)

**Verdict**: GUAC is **HIGHLY EFFECTIVE** for base image poisoning detection and supply chain analysis. **This is one of GUAC's primary use cases**. Essential for understanding supply chain relationships.

### Summary for Challenge 3

| Tool | Effectiveness | Primary Gap |
|------|---------------|-------------|
| SLSA Provenance | ✅ Highly effective | Must verify base image builder identity |
| SBOMs | ✅ Highly effective | Requires baseline for comparison |
| Scorecard | ✅ Effective | Repository-level trust only |
| AMPEL | ✅ Highly effective | Perfect use case for attestation policies |
| Conforma | ✅ Highly effective | Strong multi-attestation enforcement |
| **Image Signatures** | ✅ **CRITICAL** | **Must verify official maintainer signatures** |
| **Tekton Chains** | ✅ **HIGHLY EFFECTIVE** | **Perfect for documenting and enforcing base images** |
| **Kubescape** | ✅ Highly effective | **Content scanning** - detects malicious binaries/configs |
| **GUAC** | ✅ **HIGHLY EFFECTIVE** | **Supply chain analysis** - PRIMARY USE CASE |

**Recommended Stack**:
1. **AMPEL** or **Conforma** to enforce SLSA provenance + SBOM
2. **Cosign** for signature verification
3. **GUAC** for supply chain graph analysis (ESSENTIAL)
4. **Kubescape/Trivy** for base image content scanning
5. **Kyverno** to require image digests (not tags)
6. **Scorecard** for upstream repository trust
7. **Tekton Chains** to document base images in provenance

**Current SECURITY-GUIDE.md status**: ✅ Well-covered (AMPEL mentioned, SBOM covered, signatures covered)

---

## Challenge 4: GitOps Pipeline Compromise

### Attack Summary
Attacker gains Git access, pushes malicious manifests to GitOps repo, ArgoCD deploys backdoored pods with excessive privileges.

### SLSA Provenance - ⚠️ LIMITED EFFECTIVENESS

**Can it help?**
- ✅ SLSA for deployment could attest that manifest came from Git repo
- ⚠️ Does NOT verify manifest content is benign
- ❌ Does NOT prevent Git compromise
- ❌ Does NOT detect privilege escalation in manifests

**Gap**: Provenance verifies "this came from Git", not "this is safe".

**Potential Use**:
```yaml
# SLSA attestation for deployment
predicate:
  buildType: "https://slsa.dev/gitops-deployment/v1"
  materials:
    - uri: "git+https://github.com/victim/production-manifests"
      digest: {"sha1": "abc123..."}
```

**Verdict**: SLSA provenance is **not sufficient** alone. Need policy enforcement.

### SBOMs - ❌ NOT APPLICABLE

**Why not?**
- Attack involves Kubernetes manifests, not software packages
- No dependencies to inventory
- Could SBOM the deployed application, but doesn't prevent manifest tampering

**Verdict**: Wrong abstraction for this attack.

### Source Verification (Scorecard) - ⚠️ LIMITED EFFECTIVENESS

**Can it help?**
- ✅ Could verify GitOps repo has branch protection
- ✅ Could check for required reviews
- ❌ Does NOT scan manifest content
- ❌ Does NOT detect privilege escalation

**Example**:
```bash
scorecard --repo=github.com/victim/production-manifests \
  --checks=Branch-Protection,Code-Review
```

**Verdict**: Helps with **Git security hygiene**, but doesn't analyze manifests.

### AMPEL - ✅ EFFECTIVE (with manifest scanning)

**Can it help?**
- ✅ Can require that manifests have been scanned by Kubescape/Checkov
- ✅ Can enforce that deployments have security attestations
- ✅ Can verify that approved users deployed changes
- ✅ Can block deployments without scan results

**Example Policy**:
```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
spec:
  checks:
    - name: manifest-scanned
      condition: |
        attestation.predicateType == "https://kubescape.io/scan/v1" &&
        attestation.predicate.riskScore < 50
      severity: CRITICAL
    
    - name: approved-deployer
      condition: |
        attestation.predicate.deployer.email in ["ops-team@company.com"]
      severity: HIGH
```

**Verdict**: AMPEL can **enforce scanning and approval gates**. Very effective if implemented.

### Conforma - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ Enforce that manifests meet security baselines (Pod Security Standards)
- ✅ Require attestations from Kubescape, Checkov, Kyverno
- ✅ Block deployments with privilege escalation
- ✅ Policy-as-code for manifest compliance

**Example**:
```yaml
apiVersion: conforma.dev/v1alpha1
kind: Policy
metadata:
  name: gitops-security
spec:
  rules:
    - name: no-privilege-escalation
      attestations:
        - type: https://kubescape.io/scan/v1
          conditions:
            - path: predicate.controls["C-0016"].status
              operator: Equals
              value: "passed"  # C-0016: Container privilege escalation
    
    - name: require-code-review
      attestations:
        - type: https://slsa.dev/provenance/v1
          conditions:
            - path: predicate.metadata.reviewers
              operator: MinLength
              value: 2
```

**Verdict**: Conforma is **ideal** for enforcing GitOps security policies.

### Image Signatures (Cosign/Sigstore) - ✅ EFFECTIVE (partial defense)

**Can it help?**
- ✅ Prevent deployment of unsigned container images in malicious manifests
- ✅ Ensure only authorized images are deployed
- ⚠️ Does NOT prevent manifest tampering (securityContext, resources, etc.)
- ❌ Does NOT detect privilege escalation in pod specs

**How it helps (partial defense)**:

**Attack scenario without signature verification**:
```yaml
# Attacker's malicious manifest
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: recipe-api
        image: attacker.com/backdoored-app:latest  # ❌ Malicious image
        securityContext:
          runAsUser: 0  # ❌ Running as root
          privileged: true  # ❌ Privileged container
```

**With signature verification**:
```yaml
# Kyverno policy requires signed images
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-images
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences: ["*"]
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...company signing key...
                      -----END PUBLIC KEY-----
```

**Result**:
- ✅ `attacker.com/backdoored-app:latest` is **BLOCKED** (no valid signature)
- ❌ But attacker can still use signed company image: `company.com/recipe-api:v1.0.0`
- ❌ Malicious `securityContext` and `privileged: true` still get deployed!

**What signatures prevent**:
1. Using completely unauthorized images
2. Deploying images from external registries
3. Tag-swapping attacks

**What signatures DON'T prevent**:
1. Privilege escalation via securityContext
2. Resource abuse (cryptomining via resource limits)
3. Adding malicious sidecars (if using signed images)
4. Changing network policies or RBAC

**Combined defense strategy**:
```yaml
# Layer 1: Require signed images (Kyverno)
- verifyImages: [...]

# Layer 2: Enforce security context (Kyverno)
- name: require-non-root
  validate:
    pattern:
      spec:
        containers:
        - securityContext:
            runAsNonRoot: true
            privileged: false

# Layer 3: Require manifest scanning attestation (AMPEL)
- checks:
    - name: manifest-scanned
      condition: attestation.predicateType == "https://kubescape.io/scan/v1"
```

**Real-world scenario**:
- Attacker gains Git access
- Pushes manifest with legitimate, signed image
- BUT changes `securityContext.privileged: true`
- Image signature ✅ PASSES (image is valid)
- Deployment proceeds with elevated privileges
- **Need Kyverno/OPA to block the securityContext change**

**Verdict**: Image signatures provide **partial defense** - they prevent unauthorized images but don't address manifest-level attacks. Must be combined with admission policies.

### Tekton Chains - ❌ NOT APPLICABLE (wrong layer)

**Can it help?**
- ❌ Tekton Chains is for **build pipelines**, not GitOps deployments
- ❌ Doesn't generate attestations for `kubectl apply` or ArgoCD sync
- ❌ Doesn't observe manifest changes in Git repos
- ⚠️ Could verify that deployed images were built by Chains (but doesn't prevent manifest tampering)

**Gap**: Challenge 4 is a **deployment-time** attack, not a build-time attack. Tekton Chains operates at the wrong layer.

**Attack timeline**:
1. Attacker gains access to production-manifests Git repo
2. Pushes malicious manifest with `privileged: true`
3. ArgoCD syncs the manifest
4. Pod deploys with excessive privileges
5. ❌ Tekton Chains never sees this (no build happened)

**Tekton Chains would only help if**:
- The attack involved building a malicious container image
- But in Challenge 4, attacker uses legitimate company image
- Only the manifest (YAML) is malicious

**What you actually need**:
- **in-toto attestations for deployments** (not Tekton Chains)
- **ArgoCD audit logs** 
- **Manifest scanning** (Kubescape/Checkov)
- **Admission control** (Kyverno/OPA)

**Partial defense scenario**:

Chains could provide **indirect protection** if you enforce that only Chains-built images can be deployed:

```yaml
# AMPEL policy: All deployed images must have Tekton Chains attestation
apiVersion: policy.ampel.dev/v1
kind: Policy
spec:
  checks:
    - name: require-chains-provenance
      condition: |
        attestation.predicateType == "https://slsa.dev/provenance/v1" &&
        attestation.predicate.buildType.startsWith("https://tekton.dev/")
      severity: CRITICAL
```

**Result**:
- ✅ Prevents deploying images from unknown sources
- ❌ But attacker can use legitimate Chains-built image
- ❌ And still set `privileged: true` in manifest

**Example attack that bypasses Chains**:
```yaml
# Malicious manifest (pushed to Git)
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: recipe-api
        image: company.com/recipe-api:v1.0.0  # ✅ Legitimate, Chains-built image
        securityContext:
          privileged: true  # ❌ But malicious securityContext added
```

**Tekton Chains attestation shows**:
```json
{
  "predicate": {
    "buildType": "https://tekton.dev/attestations/chains@v2",
    "materials": [...]  # All legitimate
  }
}
# ✅ Attestation is valid
# ❌ But doesn't prevent manifest tampering
```

**What would actually work**:

Instead of Tekton Chains, you need **deployment attestations**:

```bash
# Generate deployment attestation (using in-toto)
in-toto-run \
  --step-name deploy-to-production \
  --materials production-manifests/ \
  --products deployment.yaml \
  --key deployment-key.pem \
  -- kubectl apply -f deployment.yaml

# Policy requires deployment attestation from authorized deployer
```

**Or use ArgoCD with policy enforcement**:

```yaml
# ArgoCD Application with pre-sync hooks
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
  # Pre-sync hook: Scan manifests before applying
  preSyncHooks:
    - name: kubescape-scan
      container:
        image: quay.io/armosec/kubescape:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            kubescape scan *.yaml --threshold 0 || exit 1
```

**Verdict**: Tekton Chains is **NOT APPLICABLE** to Challenge 4. This is a deployment/manifest attack, not a build attack. Use manifest scanning and admission control instead.

### Kubescape - ✅ HIGHLY EFFECTIVE

**Can it help?**
- ✅ **PRIMARY TOOL**: Scans Kubernetes manifests for security misconfigurations
- ✅ Detects privilege escalation in pod specs (`privileged: true`, `runAsUser: 0`)
- ✅ Identifies excessive RBAC permissions
- ✅ Scans against NSA/CISA hardening guidelines
- ✅ Can be integrated into GitOps pipelines (ArgoCD, Flux)
- ✅ Provides compliance scoring and risk assessment
- ✅ Can block deployments via admission control

**This is Kubescape's STRONGEST use case!**

**How Kubescape prevents this attack**:

**Step 1: Scan manifests before deployment**:

```bash
# Scan malicious deployment manifest
kubescape scan manifest deployment.yaml --format json

# Example findings for malicious manifest:
{
  "results": [
    {
      "resourceID": "Deployment/recipe-api",
      "controls": [
        {
          "controlID": "C-0016",
          "name": "Allow privilege escalation",
          "severity": "HIGH",
          "status": "failed",
          "failedResources": [
            {
              "path": "spec.template.spec.containers[0].securityContext.privileged",
              "value": true,
              "reason": "Container has privileged flag set to true"
            }
          ]
        },
        {
          "controlID": "C-0013",
          "name": "Non-root containers",
          "severity": "MEDIUM",
          "status": "failed",
          "failedResources": [
            {
              "path": "spec.template.spec.containers[0].securityContext.runAsUser",
              "value": 0,
              "reason": "Container running as root (UID 0)"
            }
          ]
        },
        {
          "controlID": "C-0035",
          "name": "Cluster-admin binding",
          "severity": "CRITICAL",
          "status": "failed"
        }
      ]
    }
  ],
  "summaryDetails": {
    "riskScore": 89  # HIGH RISK!
  }
}
```

**Step 2: Integration with ArgoCD**:

```yaml
# ArgoCD Application with Kubescape pre-sync hook
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: recipe-api
spec:
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
    preSyncHooks:
      - name: kubescape-security-scan
        container:
          image: quay.io/armosec/kubescape:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              # Scan manifests before sync
              kubescape scan /manifests \
                --threshold 0 \
                --fail-threshold-severity HIGH \
                --format json

              # Exit 1 if scan fails (blocks deployment)
              if [ $? -ne 0 ]; then
                echo "❌ Manifest failed Kubescape security scan"
                exit 1
              fi
              
              echo "✅ Manifest passed security checks"
```

**Step 3: Admission control with Kubescape operator**:

```bash
# Install Kubescape operator for runtime admission control
kubectl apply -f https://github.com/kubescape/kubescape-operator/releases/latest/download/kubescape-operator.yaml

# Configure admission policy
kubectl apply -f - <<EOF
apiVersion: kubescape.io/v1
kind: AdmissionPolicy
metadata:
  name: block-privilege-escalation
spec:
  controls:
    - C-0016  # Allow privilege escalation
    - C-0013  # Non-root containers
    - C-0035  # Cluster-admin binding
  failureAction: Deny
  severity: HIGH
EOF
```

**Real-world workflow**:

```bash
# Attacker pushes malicious manifest to Git
git add deployment.yaml
git commit -m "Update resource limits"  # Hiding the privilege escalation
git push origin main

# ArgoCD detects Git change, attempts sync
# Pre-sync hook runs Kubescape:

kubescape scan deployment.yaml --fail-threshold-severity HIGH

# Output:
❌ Deployment failed security scan!
Controls failed:
  - C-0016: Allow privilege escalation (CRITICAL)
  - C-0013: Non-root containers (MEDIUM)
  - C-0035: Cluster-admin binding (CRITICAL)

Risk Score: 89/100

# ArgoCD sync BLOCKED - malicious manifest NOT deployed! ✅
```

**Kubescape control coverage for this attack**:

| Control ID | Name | Detects |
|------------|------|---------|
| **C-0016** | Allow privilege escalation | `privileged: true`, `allowPrivilegeEscalation` |
| **C-0013** | Non-root containers | `runAsUser: 0` |
| **C-0017** | Immutable container filesystem | `readOnlyRootFilesystem: false` |
| **C-0034** | Automatic mapping of service account | Excessive ServiceAccount permissions |
| **C-0035** | Cluster-admin binding | ClusterRoleBinding to cluster-admin |
| **C-0053** | Access to Kubernetes API | Pods with API access |
| **C-0057** | Privileged container | `privileged: true` |

**Integration with AMPEL**:

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
metadata:
  name: require-kubescape-manifest-scan
spec:
  checks:
    - name: kubescape-scan-passed
      description: Manifest must pass Kubescape security scan
      condition: |
        attestation.predicateType == "https://kubescape.io/scan/v1" &&
        attestation.predicate.riskScore < 50 &&
        attestation.predicate.controls.filter(c => c.severity == "CRITICAL" && c.status == "failed").length == 0
      severity: CRITICAL
      message: "Manifest failed Kubescape security scan - risk score too high"
```

**Advantages**:
1. **Manifest-specific**: Designed for Kubernetes YAML analysis
2. **Framework coverage**: NSA, MITRE, CIS, SOC2, PCI-DSS
3. **Pre-deployment**: Catches issues before they reach cluster
4. **Detailed findings**: Exact path to problem in manifest
5. **Risk scoring**: Quantifiable security posture
6. **GitOps-friendly**: Easy integration with ArgoCD/Flux

**Verdict**: Kubescape is **HIGHLY EFFECTIVE** for Challenge 4. **This is its PRIMARY use case** - scanning Kubernetes manifests for security issues before deployment.

### GUAC - ⚠️ LIMITED EFFECTIVENESS (audit trail)

**Can it help?**
- ⚠️ Does NOT scan manifests for security issues
- ⚠️ Does NOT prevent manifest tampering
- ✅ Can track deployment provenance (who deployed what, when)
- ✅ Provides audit trail for GitOps changes
- ✅ Can answer "what changed in this deployment?"
- ⚠️ Useful for forensics, not prevention

**How GUAC helps (post-incident analysis)**:

```bash
# Scenario: Malicious deployment discovered

# 1. Query: When was this malicious configuration deployed?
guacone query "
  MATCH (deployment:Deployment {name: 'recipe-api', namespace: 'production'})
        -[:DEPLOYED_BY]->(actor:Person)
  RETURN deployment.timestamp, actor.email, deployment.manifest_hash
"

# Output:
| timestamp           | actor.email          | manifest_hash |
|---------------------|----------------------|---------------|
| 2026-04-20T14:32:00 | attacker@company.com | sha256:abc... |

# 2. Query: What changed compared to previous deployment?
guacone query "
  MATCH (current:Deployment)-[:REPLACES]->(previous:Deployment)
  WHERE current.name = 'recipe-api'
  RETURN current.manifest, previous.manifest
"

# 3. Query: What other deployments did this actor make?
guacone query "
  MATCH (actor:Person {email: 'attacker@company.com'})
        -[:DEPLOYED]->(deployment:Deployment)
  RETURN deployment.name, deployment.namespace, deployment.timestamp
"

# Shows blast radius of compromised account
```

**Integration with GitOps**:

```bash
# Ingest ArgoCD/Flux sync events into GUAC
guacone collect kubernetes deployment-events.json

# GUAC creates graph:
[Git Commit] → [ArgoCD Sync] → [Deployment Created] → [Pods Running]
     ↑                               ↑
  [Author]                      [ServiceAccount]
```

**Useful queries for incident response**:

```bash
# Find all deployments with privilege escalation
guacone query "
  MATCH (deployment:Deployment)
  WHERE deployment.spec CONTAINS 'privileged: true'
  RETURN deployment.name, deployment.namespace, deployment.cluster
"

# Track configuration drift over time
guacone query "
  MATCH path = (d1:Deployment)-[:REPLACES*]->(d2:Deployment)
  WHERE d1.name = 'recipe-api'
  RETURN path
"
```

**Limitations**:
- Requires ingestion of deployment metadata
- Does NOT analyze manifest security
- Does NOT prevent malicious changes
- Post-deployment visibility only
- No real-time prevention

**Value proposition for Challenge 4**:
1. **Audit trail**: "Who deployed this malicious manifest?"
2. **Change tracking**: "What exactly changed?"
3. **Attribution**: "Which Git commit introduced this?"
4. **Forensics**: "When did the attack happen?"
5. **Blast radius**: "What else did the attacker deploy?"

**Verdict**: GUAC provides **audit trail and forensics** but does NOT prevent the attack. Use Kubescape for prevention, GUAC for post-incident analysis.

### Summary for Challenge 4

| Tool | Effectiveness | Primary Gap |
|------|---------------|-------------|
| SLSA Provenance | ⚠️ Limited | Verifies source, not safety |
| SBOMs | ❌ Not applicable | Wrong abstraction (manifests vs packages) |
| Scorecard | ⚠️ Limited | Git hygiene only, not manifest content |
| AMPEL | ✅ Effective | Requires integration with scanners |
| Conforma | ✅ Highly effective | Perfect for manifest compliance |
| **Image Signatures** | ✅ Partial | Blocks unauthorized images, not manifest attacks |
| **Tekton Chains** | ❌ Not applicable | Wrong layer (build vs deployment) |
| **Kubescape** | ✅ **HIGHLY EFFECTIVE** | **PRIMARY TOOL** for manifest security |
| **GUAC** | ⚠️ Limited | Audit trail only, not prevention |

**Recommended Stack**:
1. **Kubescape** for manifest security scanning (MUST-HAVE)
2. **Conforma** or **AMPEL** to enforce Kubescape scan attestations
3. **Kyverno** for runtime admission control (defense in depth)
4. **Falco** for runtime detection
5. **Git branch protection** + **CODEOWNERS** for approval gates
6. **GUAC** for deployment audit trail and forensics

**Current SECURITY-GUIDE.md status**: ⚠️ Missing AMPEL/Conforma - relies on Kyverno only

---

## Cross-Cutting Analysis

### When SLSA Provenance is Most Valuable

✅ **Best for**:
- Verifying build integrity (Challenge 3: base images)
- Detecting supply chain substitution attacks
- Ensuring artifacts came from expected sources

❌ **Limitations**:
- Does NOT analyze artifact content (needs scanners)
- Does NOT prevent runtime attacks
- Does NOT verify configuration correctness

### When SBOMs are Most Valuable

✅ **Best for**:
- Detecting unexpected dependencies (Challenge 3)
- Vulnerability management
- License compliance
- Supply chain risk assessment

❌ **Limitations**:
- Does NOT detect secrets in images (Challenge 2)
- Does NOT apply to configuration (Challenge 4)
- Does NOT prevent CI/CD abuse (Challenge 1)

### When AMPEL is Most Valuable

✅ **Best for**:
- **All challenges when combined with appropriate scanners**
- Enforcing that artifacts have required attestations
- Policy-as-code for supply chain security
- Blocking non-compliant deployments

❌ **Limitations**:
- Requires integration with scanning tools
- Needs well-designed policies
- Post-hoc enforcement (happens after build)

### When Conforma is Most Valuable

✅ **Best for**:
- Multi-attestation compliance enforcement
- Manifest security (Challenge 4)
- Image compliance (Challenge 2, 3)
- Complex policy scenarios

❌ **Limitations**:
- Similar to AMPEL - requires scanner integration
- Complexity can be high for simple use cases

### When Image Signatures are Most Valuable

✅ **Best for**:
- **Challenge 3: Base image poisoning** (PRIMARY USE CASE)
- Verifying artifact authenticity (who built this?)
- Detecting tag-swapping attacks
- Ensuring only authorized builders produce artifacts
- Preventing unauthorized image deployment

❌ **Limitations**:
- Does NOT scan artifact contents (need Trivy/Kubescape)
- Does NOT prevent CI/CD attacks (Challenge 1)
- Does NOT detect secrets in images (Challenge 2)
- Does NOT prevent manifest tampering (Challenge 4)

**Key insight**: Image signatures verify **WHO** built something and **INTEGRITY** (not tampered), but not **WHAT** it contains or **HOW SAFE** it is.

**Defense-in-depth strategy**:
1. **Signatures** = Authenticity & Integrity
2. **SLSA Provenance** = Build environment verification
3. **SBOM** = Content inventory
4. **Scanners** = Vulnerability & secret detection
5. **Policies (Kyverno/OPA)** = Deployment rules

**Example requirement**:
> "All images must have: (1) Valid signature from trusted builder, AND (2) SLSA L3 provenance, AND (3) SBOM, AND (4) Clean secret scan, AND (5) No HIGH/CRITICAL CVEs"

This is where **AMPEL** or **Conforma** excel - they enforce all these requirements together.

### When Tekton Chains is Most Valuable

✅ **Best for**:
- **Challenge 2: Leaked secrets** (when integrated with scanning tasks)
- **Challenge 3: Base image poisoning** (PRIMARY USE CASE - documents base images)
- Automatic SLSA provenance generation for builds
- Capturing build materials and results in attestations
- Audit trail for all pipeline executions
- Integration with AMPEL/Conforma for policy enforcement

❌ **Limitations**:
- Does NOT prevent attacks (only documents them)
- Operates at build layer, not deployment layer (Challenge 4)
- Doesn't detect CI/CD workflow vulnerabilities (Challenge 1)
- Requires integration with scanners for content security
- Post-hoc only (attestation after execution)

**Key insight**: Tekton Chains is a **provenance generation and attestation tool**, not a scanning or prevention tool. It automatically creates signed records of what happened during builds.

**When Chains is HIGHLY EFFECTIVE**:
1. **Challenge 3**: Documenting which base images were used (materials)
2. **Challenge 2**: Recording scan results when pipelines include scanning tasks
3. **Forensics**: Understanding what happened after an incident
4. **Policy enforcement**: AMPEL can enforce policies based on Chains attestations

**When Chains is LIMITED**:
1. **Challenge 1**: Attack happens during build, Chains only records it afterward
2. **Challenge 4**: Not applicable - this is deployment, not build

**Tekton Chains value proposition**:
- **Automatic**: No manual attestation generation
- **Tamper-proof**: Signed with Sigstore
- **Standardized**: SLSA provenance format
- **Verifiable**: Can be checked before deployment
- **Auditable**: Complete build history

**Integration with other tools**:
```
[Tekton Pipeline] → [Build + Scan Tasks] → [Complete]
                            ↓
                   [Tekton Chains Observer]
                            ↓
            [Generate SLSA Provenance + Results]
                            ↓
                   [Sign with Sigstore]
                            ↓
              [Store with image in registry]
                            ↓
    [AMPEL/Conforma verify before deployment]
                            ↓
          [Kyverno admits if policy passes]
```

**Example policy requirement**:
> "All images must have Tekton Chains attestation showing: (1) Official base image used, (2) Secret scan task completed with PASS, (3) Signed by authorized Tekton instance"

### When Kubescape is Most Valuable

✅ **Best for**:
- **Challenge 4: GitOps Compromise** (PRIMARY USE CASE - manifest security scanning)
- **Challenge 2: Leaked Secrets** (image layer scanning for secrets)
- **Challenge 3: Base Image Poisoning** (scanning base image content for malware)
- Pre-deployment security validation (images and manifests)
- Compliance checking (NSA, CIS, MITRE, SOC2)
- Kubernetes-specific security analysis
- Detecting misconfigurations and privilege escalation

❌ **Limitations**:
- Does NOT analyze CI/CD workflow configurations (Challenge 1)
- Does NOT verify provenance or signatures (use Cosign/Chains)
- Does NOT build supply chain graphs (use GUAC)
- Scans content and configuration, not authenticity

**Key insight**: Kubescape is the **scanner** for Kubernetes environments - it analyzes what you have (images, manifests, clusters) and tells you what's wrong. It's preventive when integrated into pipelines/GitOps.

**Primary use cases**:
1. **Manifest security** (Challenge 4): Detect privilege escalation, RBAC issues
2. **Image security** (Challenges 2, 3): Find secrets, malware, vulnerabilities
3. **Cluster posture** (All challenges): Continuous compliance monitoring
4. **Admission control** (Challenges 2, 3, 4): Block insecure resources at deployment

**Integration points**:
- Tekton pipelines (scan images during build)
- ArgoCD/Flux (scan manifests before sync)
- Admission webhooks (runtime enforcement)
- CI/CD (fail builds on security violations)

### When GUAC is Most Valuable

✅ **Best for**:
- **Challenge 3: Base Image Poisoning** (PRIMARY USE CASE - supply chain provenance tracking)
- Understanding "where did this artifact come from?"
- Blast radius analysis ("what depends on this vulnerable component?")
- Incident response ("which deployments are affected?")
- Supply chain anomaly detection ("is this from expected source?")
- Historical analysis ("when did this dependency change?")
- Cross-tool correlation (SBOMs + provenance + vulnerabilities)

❌ **Limitations**:
- Does NOT scan artifacts for vulnerabilities (use Kubescape/Trivy)
- Does NOT prevent attacks in real-time (post-build analysis)
- Does NOT verify signatures (use Cosign)
- Does NOT enforce policies (use AMPEL/Conforma)
- Requires metadata ingestion (SBOMs, provenance, etc.)

**Key insight**: GUAC is the **knowledge graph** for your supply chain - it doesn't scan or prevent, it connects the dots. It tells you **relationships** and **context** that other tools miss.

**Primary use cases**:
1. **Provenance tracking** (Challenge 3): "Which builder created this image?"
2. **Dependency analysis** (Challenge 3): "What base images are we using?"
3. **Blast radius** (Challenges 2, 3): "What's affected by this vulnerability?"
4. **Incident response** (All challenges): "What happened and where?"
5. **Policy queries** (Challenges 3, 4): "Do all images come from trusted sources?"

**Example questions GUAC answers**:
```bash
# "Show me all applications built from untrusted base images"
guacone query "MATCH (app)-[:BUILT_FROM]->(base) WHERE base.repository != 'docker.io/library' RETURN app, base"

# "What's the blast radius of this leaked secret?"
guacone query "MATCH (app)-[:CONTAINS]->(file {path: '.env'}) RETURN app, app.deployments"

# "Which deployments use this poisoned base image?"
guacone query "MATCH (deploy)-[:USES]->(app)-[:BUILT_FROM]->(base {digest: 'sha256:...'}) RETURN deploy"

# "Has this vulnerability been exploited in the wild?"
guacone query "MATCH (cve:CVE)-[:AFFECTS]->(pkg)-[:USED_BY]->(app) WHERE cve.epss > 0.8 RETURN app"
```

**Integration with other tools**:
```
[Kubescape] ──┐
[Trivy]     ──┤
[Syft]      ──┼─→ [GUAC Knowledge Graph] ←─→ [AMPEL/Conforma Policy Queries]
[Chains]    ──┤
[Scorecard] ──┘
```

GUAC doesn't replace scanners - it **enriches their results with context**.

**Kubescape vs GUAC**:

| Aspect | Kubescape | GUAC |
|--------|-----------|------|
| **Function** | Scanner (finds problems) | Graph (connects dots) |
| **When** | Pre-deployment, runtime | Post-build, incident response |
| **Input** | Images, manifests, clusters | SBOMs, provenance, attestations |
| **Output** | Vulnerabilities, misconfigs | Relationships, dependencies |
| **Prevention** | ✅ Yes (blocks bad configs) | ❌ No (analysis only) |
| **Detection** | ✅ Yes (scans for issues) | ⚠️ Indirect (via queries) |
| **Best for** | Challenges 2, 4 | Challenge 3 |
| **Use with** | Tekton, ArgoCD, admission | AMPEL, Conforma, forensics |

**Combined workflow**:
1. **Kubescape scans** image and finds secret → generates attestation
2. **Tekton Chains** captures scan result in provenance → signs it
3. **GUAC ingests** attestation + SBOM → builds graph
4. **AMPEL queries GUAC** to verify base image provenance → enforces policy
5. **Kubescape operator** blocks deployment if policy fails → prevents breach

**Defense-in-depth strategy**:
```
[Kubescape] = Content security (what's in it?)
[GUAC]      = Supply chain security (where did it come from?)
[AMPEL]     = Policy enforcement (does it meet requirements?)
[Kyverno]   = Runtime control (can it run here?)
```

All four are needed for comprehensive supply chain security.

---

## Gap Analysis: Current SECURITY-GUIDE.md Files

### Challenge 1 (Pull Request Target)
- ✅ Has comprehensive security guide
- ✅ Mentions SLSA in references
- ❌ Missing AMPEL/Conforma evaluation
- ✅ Correctly emphasizes Scorecard/Zizmor
- **Recommendation**: Document why SLSA/SBOM are not sufficient

### Challenge 2 (Container Layer Leaks)
- ❌ **MISSING SECURITY-GUIDE.md entirely**
- **Recommendation**: Create guide covering:
  - Trivy/Kubescape secret scanning
  - AMPEL/Conforma to enforce scan attestations
  - Why SBOM alone is insufficient

### Challenge 3 (Base Image Poisoning)
- ✅ Has comprehensive security guide
- ✅ Covers AMPEL, SBOMs, Sigstore
- ✅ Well-aligned with supply chain tools
- ⚠️ Missing Conforma
- **Recommendation**: Add Conforma policy example

### Challenge 4 (GitOps Compromise)
- ✅ Has comprehensive security guide
- ❌ Missing AMPEL/Conforma for manifest attestation
- ✅ Good coverage of runtime controls (Kyverno, Falco)
- **Recommendation**: Add AMPEL/Conforma for deployment attestations

---

## Recommendations for Documentation Updates

### 1. Add to Challenge 1 SECURITY-GUIDE.md

Add section:

```markdown
## Why SLSA/SBOM are Not Sufficient for This Attack

**SLSA Provenance**: Documents build process, but attack happens BEFORE build completes.
**SBOMs**: Inventory dependencies, but attack uses inline malicious code.

**What Works**: 
- Scorecard/Zizmor for workflow analysis
- RBAC for permission boundaries
- Network Policies for exfiltration prevention
```

### 2. Create Challenge 2 SECURITY-GUIDE.md

**Required sections**:
- Trivy/Kubescape secret scanning
- AMPEL policy for requiring scan attestations
- Conforma multi-attestation enforcement
- Pre-commit hooks (git-secrets, talisman)
- Why traditional SBOMs miss secrets

### 3. Update Challenge 3 SECURITY-GUIDE.md

Add Conforma policy example:

```yaml
apiVersion: conforma.dev/v1alpha1
kind: Policy
metadata:
  name: base-image-verification
spec:
  rules:
    - name: require-slsa-provenance
      attestations:
        - type: https://slsa.dev/provenance/v1
    - name: require-sbom
      attestations:
        - type: https://spdx.dev/Document
    - name: require-signature
      attestations:
        - type: https://cosign.sigstore.dev/attestation/v1
```

### 4. Update Challenge 4 SECURITY-GUIDE.md

Add section:

```markdown
## Deployment Attestation with AMPEL/Conforma

Enforce that GitOps deployments have been scanned and approved:

```yaml
apiVersion: policy.ampel.dev/v1
kind: Policy
spec:
  checks:
    - name: manifest-security-scan
      condition: attestation.predicate.tool == "kubescape"
    - name: human-approval
      condition: len(attestation.predicate.approvers) >= 2
```

### 5. Add to docs/references.md

Add specific AMPEL/Conforma examples:
- Link to AMPEL blog post (already present)
- Add Conforma getting started guide
- Add SLSA provenance verification examples
- Add SBOM comparison tooling (sbom-diff, etc.)

---

## Conclusion

### Overall Effectiveness Matrix

| Attack Type | SLSA | SBOM | Scorecard | AMPEL | Conforma | Signatures | Chains | **Kubescape** | **GUAC** |
|-------------|------|------|-----------|-------|----------|------------|--------|---------------|----------|
| Challenge 1: CI/CD Token Theft | ⚠️ | ❌ | ✅ | ⚠️ | ❌ | ❌ | ⚠️ | ⚠️ | ❌ |
| Challenge 2: Leaked Secrets | ⚠️ | ⚠️ | ❌ | ✅ | ✅ | ⚠️ | ✅ | ✅ | ⚠️ |
| Challenge 3: Base Image Poisoning | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Challenge 4: GitOps Compromise | ⚠️ | ❌ | ⚠️ | ✅ | ✅ | ⚠️ | ❌ | ✅ | ⚠️ |

**Legend**: ✅ Highly Effective | ⚠️ Partially Effective/Limited | ❌ Not Applicable/Ineffective

**Key Insights**:

1. **No single tool prevents all attacks** - Defense in depth is essential

2. **AMPEL and Conforma are highly effective when combined with scanners** - They enforce attestation requirements

3. **Image signatures are CRITICAL for Challenge 3 (base image poisoning)** - Their primary use case

4. **Tekton Chains excels at Challenges 2 & 3** - Automatic provenance generation with scan results and base image tracking

5. **SLSA provenance is critical for supply chain integrity** (Challenge 3), but not sufficient alone

6. **SBOMs are valuable for dependency analysis** but need augmentation for secrets/config

7. **Scorecard is underutilized** - Should be mandatory in CI for workflow security

8. **Image signatures verify authenticity, not safety** - Must combine with content scanning (Trivy/Kubescape)

9. **Tekton Chains provides forensics, not prevention** - Documents what happened, enabling policy enforcement via AMPEL/Conforma

10. **Kubescape is the go-to scanner for Kubernetes environments** - Excels at manifest security (Challenge 4) and image scanning (Challenges 2 & 3)

11. **GUAC shines for supply chain analysis** - Challenge 3 (base image provenance) is a PRIMARY use case; provides blast radius analysis and audit trails

### Recommended Security Stack

**Minimum viable supply chain security**:
1. **Tekton Chains** for automatic SLSA provenance generation
2. **Image Signatures** (Cosign/Sigstore) for artifact authenticity
3. **AMPEL** or **Conforma** for multi-attestation enforcement
4. **Kubescape** for image and manifest scanning (integrated into Tekton pipelines and GitOps)
5. **GUAC** for supply chain graph analysis and blast radius assessment
6. **Scorecard** for repository security analysis (CI/CD workflows)
7. **Kyverno** for runtime admission control
8. **Falco** for runtime threat detection
9. **SBOM generation** with Syft/Trivy (automated in pipelines)

**Tool Selection by Use Case**:
- **Image scanning**: Kubescape or Trivy (Kubescape for K8s-specific checks, Trivy for CVEs)
- **Manifest scanning**: Kubescape (PRIMARY tool for K8s manifests)
- **Supply chain analysis**: GUAC (PRIMARY tool for provenance tracking and dependency graphs)
- **Workflow scanning**: Scorecard or Zizmor (GitHub Actions/Tekton workflows)
- **Policy enforcement**: AMPEL or Conforma (attestation-based admission)
- **Runtime policy**: Kyverno or OPA (admission control)

**Integration architecture**:
```
[Git Push] → [Scorecard Scan]
                  ↓
         [Tekton Pipeline Triggered]
                  ↓
         ┌────────────────────────────────┐
         │  Tekton PipelineRun            │
         │  - Verify base image (Cosign)  │
         │  - Scan base image (Kubescape) │
         │  - Build application           │
         │  - Scan for secrets (Kubescape)│
         │  - Generate SBOM (Syft)        │
         │  - Sign with Cosign            │
         └────────────────────────────────┘
                  ↓
         [Tekton Chains Observer]  ← Automatically watches PipelineRuns
                  ↓
    [Generate SLSA Provenance]
         - Materials (base images, source repo)
         - Build steps
         - Scan results (Kubescape, secrets, vulns)
         - SBOM reference
                  ↓
    [Sign Attestation (Sigstore)]
                  ↓
    [Store with Image in Registry]
         - Image + Signature
         - SLSA Provenance Attestation
         - SBOM Attestation
         - Kubescape Scan Attestations
                  ↓                    ↓
    [GUAC Ingestion] ←──────────────────┘
         - Builds supply chain graph
         - Tracks base image provenance
         - Correlates SBOMs + attestations
         - Enables blast radius queries
                  ↓
    [AMPEL/Conforma Policy Check]
         - Verify Chains attestation exists
         - Check base image is official (via GUAC)
         - Ensure Kubescape scan passed
         - Validate SBOM present
                  ↓
    [Kyverno Admission Control]
         - Verify image signature
         - Enforce security context
         - Check attestation policies
         - Query GUAC for provenance
                  ↓
         [Deploy to Kubernetes]
                  ↓
    [Kubescape Operator] (admission control)
         - Scans manifests on admission
         - Blocks privileged pods
         - Enforces security policies
                  ↓
    [Falco Runtime Monitoring]
         - Detects runtime anomalies
         - Monitors process execution
```

**Policy enforcement layers**:
1. **Pre-build**: Scorecard scans CI/CD workflows
2. **Build-time**: Tekton Chains captures materials, steps, results
3. **Post-build**: Chains generates signed SLSA provenance with all scan results
4. **Pre-deployment**: AMPEL/Conforma verify Chains attestations meet policies
5. **Admission**: Kyverno verifies signatures + enforces security policies
6. **Runtime**: Falco detects anomalous behavior

**Why Tekton Chains is central**:
- **Automatic**: No manual attestation generation needed
- **Comprehensive**: Captures everything in one signed artifact
- **Standardized**: SLSA provenance format
- **Verifiable**: AMPEL/Conforma can enforce policies on it
- **Auditable**: Complete, tamper-proof history

This evaluation should guide updates to all SECURITY-GUIDE.md files.
