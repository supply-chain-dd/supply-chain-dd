# Attack Analysis: Malware in Base Container Image

## Attack Overview

**Attack Type**: Supply Chain Compromise - Base Image Poisoning  
**MITRE ATT&CK**: T1525 (Implant Internal Image), T1204 (User Execution)  
**Severity**: CRITICAL  
**CVSS Score**: 9.8 (Critical)

## Technical Explanation

### Attack Vector

Base image poisoning is a supply chain attack where an attacker compromises or replaces a commonly used container base image with a malicious version. When developers build applications using the poisoned base image, the malware becomes embedded in all derived images.

### Attack Chain

```
1. Attacker obtains registry write access
   ↓
2. Attacker creates malicious base image (includes backdoor/malware)
   ↓
3. Attacker pushes image with legitimate-looking tag (golang:1.25-alpine)
   ↓
4. Legitimate build pipeline pulls base image
   ↓
5. Application built on top of poisoned base
   ↓
6. Malware embedded in final production image
   ↓
7. Production deployment executes malware
   ↓
8. Attacker achieves persistence, data exfiltration, or other objectives
```

### Why This Attack Works

1. **Mutable Tags**: Using `:latest` or version tags (`:1.25-alpine`) instead of immutable digests (`@sha256:abc123...`)
2. **No Signature Verification**: Pipeline doesn't verify image signatures (e.g., Sigstore/Cosign)
3. **No SBOM Validation**: No Software Bill of Materials checking for unexpected components
4. **Implicit Trust**: Developers trust the base image source without verification
5. **Delayed Detection**: Malware may remain dormant until specific conditions are met

### Vulnerability Details

**CWE-494**: Download of Code Without Integrity Check  
**CWE-506**: Embedded Malicious Code

The vulnerability exists because:
- Container images are pulled by **tag** (mutable) not **digest** (immutable)
- No cryptographic verification of image provenance
- No attestation or SLSA compliance requirements
- Build systems often run with elevated privileges

## Real-World Attack Examples

### 1. XZ Utils Backdoor (CVE-2024-3094)

**Date**: March 2024  
**Impact**: Critical supply chain compromise affecting multiple Linux distributions

**Details**:
- Attacker "Jia Tan" gained maintainer access to XZ Utils over 2+ years
- Injected sophisticated backdoor into upstream source
- Backdoor embedded in compressed tarballs (not visible in git)
- Would have affected systemd SSH authentication if deployed

**Relevance**: Shows how upstream compromise propagates through supply chains. Container base images with XZ Utils would have been poisoned.

**References**:
- CVE-2024-3094
- https://www.openwall.com/lists/oss-security/2024/03/29/4

### 2. Codecov Supply Chain Attack

**Date**: April 2021  
**Impact**: Thousands of companies affected, credentials stolen

**Details**:
- Attacker modified Codecov Bash Uploader script
- Script executed in CI/CD pipelines
- Exfiltrated environment variables containing secrets
- Affected: Hashicorp, Confluent, Rapid7, others

**Relevance**: Demonstrates CI/CD as attack surface. Similar attack vector to base image poisoning.

**References**:
- https://about.codecov.io/security-update/

### 3. Malicious Docker Images on Docker Hub

**Date**: Ongoing (2017-present)  
**Impact**: Millions of pulls of cryptominers and backdoors

**Details**:
- Researchers found 30+ malicious images on Docker Hub
- Images contained cryptocurrency miners
- Typosquatting official images (e.g., `alipne` vs `alpine`)
- Downloaded millions of times before removal

**Examples**:
- `alpine-linux` (typosquat) - 5M+ pulls with cryptominer
- `node-alpine` (fake) - embedded reverse shell

**References**:
- https://www.reversinglabs.com/blog/mining-for-malware-cryptominers
- https://unit42.paloaltonetworks.com/malware-in-container-images/

### 4. SolarWinds Orion Supply Chain Attack

**Date**: December 2020  
**Impact**: 18,000+ organizations compromised

**Details**:
- Attackers compromised SolarWinds build system
- Injected SUNBURST backdoor into Orion software
- Distributed through official update mechanism
- Affected US Government agencies, Fortune 500

**Relevance**: Shows how build system compromise enables supply chain attacks. Container registries are analogous distribution points.

**References**:
- https://www.crowdstrike.com/blog/sunburst-malware-technical-analysis/

### 5. Kinsing Malware in Container Images

**Date**: 2020-2024 (ongoing)  
**Impact**: Widespread cryptocurrency mining in cloud environments

**Details**:
- Malware targets misconfigured Docker daemons and registries
- Deploys rootkits and cryptocurrency miners
- Persists by modifying base images in private registries
- Spreads laterally through container environments

**References**:
- https://www.aquasec.com/blog/threat-alert-kinsing-malware/

## Attack Impact

### Immediate Impact

- **Code Execution**: Arbitrary code runs in production containers
- **Credential Theft**: Access to secrets, environment variables, Kubernetes tokens
- **Data Exfiltration**: Application data, customer information, intellectual property
- **Resource Hijacking**: Cryptocurrency mining, DDoS participation

### Long-Term Impact

- **Persistent Access**: Malware embeds in all future builds using poisoned base
- **Supply Chain Contamination**: Every application built with poisoned image is compromised
- **Trust Erosion**: Loss of confidence in container supply chain
- **Regulatory Consequences**: Compliance violations (SOC2, PCI-DSS, GDPR)

## Technical Indicators

### Image Analysis Red Flags

```bash
# Unexpected files in base image
podman run --rm <image> find /usr/local/bin -type f -newer /bin/sh

# Suspicious processes at runtime
podman top <container> -eo pid,comm,args | grep -E 'nc|bash|curl'

# Modified entrypoints or CMD
podman inspect <image> --format '{{.Config.Entrypoint}}'
podman inspect <image> --format '{{.Config.Cmd}}'

# Unexpected network connections
podman run --rm <image> netstat -an | grep ESTABLISHED
```

### Build Log Indicators

- Base image pulled from unexpected registry
- Image digest changed without tag update
- Unsigned images accepted
- SBOM generation skipped or failed

### Runtime Indicators

- Unexpected outbound network connections
- High CPU usage (cryptomining)
- Processes running as root unnecessarily
- Files written to unusual locations (`/tmp/.hidden`)

## Attacker Techniques

### Stealth Methods

1. **Time-Delayed Activation**: Malware dormant for X days to evade testing
2. **Conditional Execution**: Only activates in production (checks env vars)
3. **Fileless Malware**: Runs in-memory, no disk artifacts
4. **Legitimate-Looking Processes**: Masquerades as system daemons

### Persistence Methods

1. **Cron Jobs**: Install scheduled tasks for callback
2. **Init Scripts**: Modify `/etc/profile.d/` or `~/.bashrc`
3. **System Services**: Create systemd units
4. **Container Escape**: Exploit kernel vulnerabilities for host access

### Evasion Techniques

1. **Anti-Forensics**: Clear logs, delete artifacts after execution
2. **Process Hiding**: Rootkit-level techniques
3. **Encrypted C2**: Communication obfuscated with TLS
4. **Living off the Land**: Use only built-in binaries (curl, nc, bash)

## Attacker Motivations

- **Espionage**: Steal intellectual property, credentials, customer data
- **Financial**: Cryptocurrency mining, ransomware deployment
- **Sabotage**: Destroy production systems, plant backdoors for later exploitation
- **Supply Chain Leverage**: Use as stepping stone to downstream customers

## Defense Complexity

**Why This Attack is Hard to Detect:**

1. **Implicit Trust**: Base images often trusted without inspection
2. **Volume**: Organizations pull thousands of images daily
3. **Legitimate Behavior**: Malware can mimic normal container operations
4. **Transient Execution**: Containers are ephemeral, evidence disappears
5. **Lack of Visibility**: Many orgs don't monitor container internals

**Why This Attack is Hard to Prevent:**

1. **Availability Pressure**: Developers need to move fast, skip verification
2. **Tooling Gaps**: Many orgs lack image signing infrastructure
3. **Upstream Dependencies**: Trusting 3rd party registries is necessary
4. **Tag Mutability**: Docker allows tag reuse, enabling substitution attacks

## Lessons Learned

1. **Never trust, always verify**: Even "official" images need validation
2. **Immutability matters**: Use digests, not tags
3. **Attestation is critical**: Require signed provenance metadata
4. **Defense in depth**: Multiple layers prevent single-point failures
5. **Supply chain visibility**: SBOM and scanning are mandatory, not optional

## References

- SLSA Framework: https://slsa.dev/
- Sigstore (Image Signing): https://www.sigstore.dev/
- NIST SSDF: https://csrc.nist.gov/publications/detail/sp/800-218/final
- CNCF Supply Chain Security: https://www.cncf.io/blog/2021/12/14/supply-chain-security/
- MITRE ATT&CK - Container Security: https://attack.mitre.org/matrices/enterprise/containers/
