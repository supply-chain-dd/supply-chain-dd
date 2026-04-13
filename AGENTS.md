# AGENTS.md

Instructions for AI agents (Claude Code, GitHub Copilot, etc.) working on this repository.

## Core Principles

1. **Stay concise** - Avoid verbose explanations, focus on actionable changes
2. **Update documentation always** - Documentation is a first-class deliverable, not an afterthought
3. **Maintain consistency** - Follow existing patterns in code, structure, and naming

## Documentation Update Requirements

### ✅ MANDATORY: Always Update These Files

| Change Type | Update File(s) |
|-------------|----------------|
| **Any user-facing change** | `README.md` |
| **Any architectural/development change** | `CLAUDE.md` |
| **New tool, dependency, or workflow** | Both `README.md` and `CLAUDE.md` |

### 📁 Challenge Folder Changes

When modifying anything in `challenges/challengeN/`, update the appropriate file:

| If you change... | Update this file | What to update |
|------------------|------------------|----------------|
| Setup steps, prerequisites, configuration | `SETUP.md` | Environment setup instructions |
| Attack execution, commands, flag discovery | `CTF-CHALLENGE-GUIDE.md` | Step-by-step attack walkthrough |
| Attack explanation, CVE references, impact | `ATTACK-ANALYSIS.md` | Technical analysis and real-world examples |
| Detection tools, prevention policies, remediation | `SECURITY-GUIDE.md` | Detection and prevention guidance |

**Rule**: If you modify Tekton manifests, scripts, or policies, update the corresponding documentation in the **same commit**.

## File-Specific Guidelines

### README.md
**Purpose**: User-facing quick start and reference

**Update when:**
- Adding new commands or Makefile targets
- Creating new challenges
- Changing environment setup steps
- Modifying access credentials or endpoints
- Adding user-facing features

**Keep concise:**
- Quick start comes first
- Commands over explanations
- Link to detailed docs instead of duplicating content

### CLAUDE.md
**Purpose**: Developer/agent reference for architecture and internals

**Update when:**
- Adding scripts or tools to `setup/`
- Changing project structure
- Adding new security tools to the attacks table
- Modifying Makefile targets
- Changing technical workflows

**Include:**
- Script architecture details
- Directory structure changes
- Development patterns
- Tool integrations

### Challenge Documentation Files

#### SETUP.md
**Focus**: Getting the environment ready for the attack

**Include:**
- Prerequisites (pods, services, repositories)
- Configuration commands
- Verification steps
- Expected initial state

**Exclude:**
- Attack execution steps (those go in CTF-CHALLENGE-GUIDE.md)
- Detection/prevention (those go in SECURITY-GUIDE.md)

#### CTF-CHALLENGE-GUIDE.md
**Focus**: Executing the attack step-by-step

**Include:**
- Attack commands with expected outputs
- Flag discovery process
- Hints for participants
- Troubleshooting common issues

**Exclude:**
- Why the attack works (that's in ATTACK-ANALYSIS.md)
- How to prevent it (that's in SECURITY-GUIDE.md)

#### ATTACK-ANALYSIS.md
**Focus**: Understanding the vulnerability

**Include:**
- Technical explanation of the attack vector
- Real-world examples (CVEs, incidents, research)
- Attack chain and impact analysis
- References to security papers or blog posts

**Exclude:**
- How to execute it (that's in CTF-CHALLENGE-GUIDE.md)
- How to prevent it (that's in SECURITY-GUIDE.md)

#### SECURITY-GUIDE.md
**Focus**: Detecting and preventing the attack

**Include:**
- Detection tools and commands
- Prevention policies (Kyverno, NetworkPolicy, RBAC)
- Security best practices
- Remediation steps

**Structure:**
```markdown
## Detection
- Tool 1: How to detect with commands
- Tool 2: What to look for

## Prevention
- Technique 1: Implementation with code/policies
- Technique 2: Configuration guidance

## Verification
- Commands to verify protections are in place
```

## Code Changes

### Scripts (setup/scripts/)
**Pattern**: Follow existing scripts
```bash
#!/bin/bash
set -euo pipefail

echo "Descriptive message about what's happening..."
# Command
echo "✅ Success message"
```

**Requirements:**
- Always use `set -euo pipefail`
- Provide verbose output for users
- Include error messages with context
- Make scripts idempotent when possible

### Tekton Resources
**Structure:**
```
challenges/challengeN/
├── tekton/                 # Vulnerable version
│   ├── tasks/
│   ├── pipelines/
│   └── triggers/
└── tekton-patched/        # Secured version
    └── (same structure)
```

**Requirements:**
- Always provide both vulnerable and secure versions
- Document differences in SECURITY-GUIDE.md
- Test both versions work as intended

### Security Policies
**Location**: `challenges/challengeN/security/`

**Types:**
- `kyverno-policies/` - Admission control policies
- `network-policies/` - Network segmentation
- `rbac/` - Role-based access control

**Requirements:**
- Test with `kubectl apply --dry-run=server`
- Document in SECURITY-GUIDE.md with explanations
- Include verification commands

### Makefile Targets
**Pattern:**
```makefile
.PHONY: target-name
target-name: ## Description shown in help
	@echo "User-visible message"
	@command
```

**Requirements:**
- Add `##` comment for `make help` output
- Prefix user messages with `@`
- Group related targets together
- Update both Makefile and CLAUDE.md

## Attack Showcase Table (CLAUDE.md)

When adding or modifying attacks, update the table in CLAUDE.md:

```markdown
| Attack | Description | Detection tools | Prevention tools |
|--------|-------------|-----------------|------------------|
| Name | Brief description | Tool1, Tool2 | Technique1, Technique2 |
```

**Detection tools**: Scanners, analyzers, runtime monitors
**Prevention tools**: Policies, controls, verification (include SBOM, Signatures, VEX where applicable)

## Common Workflows

### Adding a New Challenge
1. Create directory: `mkdir -p challenges/challengeN/{tekton,security,tekton-patched}`
2. Create docs: `SETUP.md`, `CTF-CHALLENGE-GUIDE.md`, `ATTACK-ANALYSIS.md`, `SECURITY-GUIDE.md`
3. Add Makefile targets: `setup-challengeN`, `verify-challengeN`
4. Update `README.md`: Add challenge description and flag
5. Update `CLAUDE.md`: Add to attacks table with tools
6. Test: `make clean && make setup && make setup-challengeN`

### Adding a Security Tool
1. Create/update setup script or Makefile target
2. Update `CLAUDE.md` attacks table
3. Document usage in relevant `SECURITY-GUIDE.md` files
4. Add verification: Update `verify-security` target
5. Update `README.md` if user-facing

### Modifying an Attack
1. Update vulnerable code/manifests in `tekton/`
2. Update secure version in `tekton-patched/`
3. Update docs:
   - Setup changes → `SETUP.md`
   - Attack steps → `CTF-CHALLENGE-GUIDE.md`
   - Technical details → `ATTACK-ANALYSIS.md`
   - Detection/prevention → `SECURITY-GUIDE.md`
4. Test both vulnerable and secure versions

## Tool Naming Conventions

- **Makefile targets**: `kebab-case` (e.g., `setup-registry`)
- **Script files**: `kebab-case.sh` (e.g., `setup-kind.sh`)
- **Documentation files**: `SCREAMING-KEBAB.md` (e.g., `SETUP.md`)
- **Kubernetes namespaces**: `kebab-case` (e.g., `ctf-challenge`)
- **Environment variables**: `SCREAMING_SNAKE_CASE` (e.g., `CLUSTER_NAME`)

## Anti-Patterns to Avoid

❌ **Don't:**
- Update code without updating documentation
- Create documentation files that duplicate information
- Add features without Makefile targets
- Skip testing with `make clean && make setup`
- Write long explanations in README.md (link to detailed docs instead)
- Commit real secrets (even in examples)

✅ **Do:**
- Update docs in the same commit as code
- Link between related documentation files
- Provide both vulnerable and secure examples
- Test end-to-end workflows
- Keep README.md concise with working commands
- Use placeholder secrets (e.g., `CTF*` patterns)

## Testing Checklist

Before considering work complete:

- [ ] Code changes tested locally
- [ ] Documentation updated (README.md, CLAUDE.md, challenge docs)
- [ ] Makefile targets added/updated (if applicable)
- [ ] `make clean && make setup` succeeds
- [ ] Challenge workflow tested end-to-end (if applicable)
- [ ] Security policies validated (if applicable)
- [ ] No real secrets committed

## Conciseness Examples

**❌ Verbose:**
> "I'm going to update the SETUP.md file to include the new configuration steps for setting up the registry, which is required before participants can execute the attack. This is important because without proper registry configuration, the attack won't work as expected."

**✅ Concise:**
> "Updating SETUP.md with registry configuration steps."

**❌ Verbose:**
> "The Kyverno policy I'm creating will prevent this attack by blocking pods that have excessive RBAC permissions. It works by checking the ServiceAccount bindings and..."

**✅ Concise:**
> "Adding Kyverno policy to block excessive RBAC permissions."

## Questions?

See CONTRIBUTING.md for more context, or check existing challenges for patterns.

---

**Remember**: Documentation is code. Treat it with the same rigor.
