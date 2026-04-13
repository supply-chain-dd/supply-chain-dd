# Contributing to Supply Chain CTF

Thank you for your interest in contributing to this supply chain security CTF project! This guide will help you understand the project structure and contribution workflow.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Set up the development environment:
   ```bash
   make setup
   make configure-registry-tls
   ```

## Project Structure

```
├── setup/                    # Environment provisioning scripts
├── challenges/               # CTF challenges
│   └── challenge*/          # Individual challenge directories
├── CLAUDE.md                # AI agent instructions
├── AGENTS.md                # Detailed AI agent guidelines
├── README.md                # User-facing documentation
└── Makefile                 # Automation interface
```

## Challenge Structure

Each challenge directory **must** contain these documentation files:

### Required Files

1. **SETUP.md**
   - Environment setup instructions
   - Prerequisites specific to this challenge
   - Configuration steps for attack preparation
   - Verification commands

2. **CTF-CHALLENGE-GUIDE.md**
   - Step-by-step attack walkthrough for participants
   - Commands to execute the attack
   - Expected outputs and flags
   - Hints and troubleshooting

3. **ATTACK-ANALYSIS.md**
   - Technical explanation of the attack vector
   - Real-world examples of similar attacks (CVEs, incidents)
   - Impact analysis and attack chain
   - References to security research

4. **SECURITY-GUIDE.md**
   - Detection methods and tools
   - Prevention techniques and best practices
   - Security policies (Kyverno, Network Policies, RBAC)
   - Remediation steps

## Contribution Guidelines

### Documentation Updates

**Always update documentation when making changes:**

- **README.md**: Update for user-facing changes (new features, commands, challenges)
- **CLAUDE.md**: Update for architecture changes, new tools, or development workflow changes
- **Challenge docs**: Update the appropriate file(s) based on the change type (see table below)

| Change Type | Update This File |
|-------------|------------------|
| Environment setup steps | `SETUP.md` |
| Attack execution steps | `CTF-CHALLENGE-GUIDE.md` |
| Attack explanation or real-world examples | `ATTACK-ANALYSIS.md` |
| Detection/prevention methods | `SECURITY-GUIDE.md` |

### Code Changes

#### Setup Scripts (`setup/scripts/`)
- Follow existing script patterns (`set -euo pipefail`)
- Add verbose output for user visibility
- Include error handling and validation
- Update the Makefile if adding new scripts
- Document in CLAUDE.md under "Script Architecture"

#### Security Tools (`challenges/*/security/`)
- Test policies before committing (use `kubectl dry-run`)
- Document policy behavior in SECURITY-GUIDE.md
- Include both vulnerable and secured configurations

#### Tekton Resources (`challenges/*/tekton/`)
- Follow Tekton best practices
- Provide both vulnerable and patched versions
- Document attack surface in ATTACK-ANALYSIS.md

### Testing Your Changes

Before submitting a pull request:

1. **Clean environment test**:
   ```bash
   make clean
   make setup
   make verify
   ```

2. **Challenge test** (if applicable):
   ```bash
   make setup-ctf-challenge
   # Follow steps in CTF-CHALLENGE-GUIDE.md
   ```

3. **Security tools test** (if applicable):
   ```bash
   make setup-security-tools
   make verify-security
   ```

4. **Documentation review**:
   - Ensure all affected files are updated
   - Check for broken links
   - Verify commands are accurate

## Adding a New Challenge

1. Create challenge directory: `challenges/challengeN/`
2. Create all required documentation files (SETUP.md, CTF-CHALLENGE-GUIDE.md, ATTACK-ANALYSIS.md, SECURITY-GUIDE.md)
3. Add vulnerable configurations in `tekton/`
4. Add security controls in `security/` and `tekton-patched/`
5. Create Makefile targets:
   - `setup-challengeN`
   - `verify-challengeN`
6. Update README.md with challenge description and flag
7. Update CLAUDE.md attack showcase table with detection/prevention tools
8. Test end-to-end workflow

## Adding Security Tools

When adding new detection or prevention tools:

1. Create setup script in `setup/scripts/` or Makefile target
2. Update the attacks table in CLAUDE.md
3. Document usage in relevant SECURITY-GUIDE.md files
4. Add verification commands to Makefile
5. Update README.md if user-facing

## Commit Guidelines

- Use clear, descriptive commit messages
- Reference issues where applicable
- Keep commits atomic (one logical change per commit)
- Update documentation in the same commit as code changes

### Commit Message Format
```
<type>: <description>

[optional body]

[optional footer]
```

**Types:**
- `feat`: New feature or challenge
- `fix`: Bug fix
- `docs`: Documentation updates
- `refactor`: Code refactoring
- `test`: Testing improvements
- `chore`: Maintenance tasks

**Examples:**
```
feat: Add challenge3 for GitOps compromise attack

docs: Update SECURITY-GUIDE.md with Falco detection examples

fix: Correct registry TLS configuration in setup-registry.sh
```

## Security Considerations

- **Never commit real secrets or credentials** (use placeholders like `CTF*` patterns)
- Ensure vulnerable configurations are **clearly marked** and isolated
- Test security policies don't break legitimate workflows
- Document security tool findings and remediation

## Pull Request Process

1. Ensure all tests pass
2. Update documentation (README.md, CLAUDE.md, challenge docs)
3. Provide clear PR description:
   - What changed
   - Why it changed
   - How to test it
4. Reference related issues
5. Request review from maintainers

## Questions or Help?

- Open an issue for bugs or feature requests
- Use discussions for questions
- Tag maintainers for urgent security issues

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Focus on learning and improving security knowledge
- This is an educational CTF project—help others learn!

---

Thank you for contributing to supply chain security education! 🔒
