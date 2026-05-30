---
name: demo-magic-script
description: Create demo-magic interactive demo scripts for the supply-chain-dd deep dive project. Use this skill whenever the user asks to create a demo script, a demo-magic script, a walkthrough script, a presentation script, or any interactive step-by-step bash demo. Also use when the user says "create a demo for challenge X", "write a demo script", "make a demo-magic script", or references *-demo.sh files.
---

# Demo-Magic Script Creator

Create interactive step-by-step demo scripts using the demo-magic framework for the supply-chain-dd deep dive project.

## Key Rules

1. **All text shown to the audience (comments, section titles, explanations) MUST be in French.** This is a hard requirement — every existing demo script in this project uses French. Variable names and commands stay in English.

2. **Source demo-magic.sh** relative to the script's location in `challenges/challengeN/`:
   ```bash
   . ../../bin/demo-magic.sh
   ```

3. **Always start with `clear`** after sourcing demo-magic.sh to hide startup output.

4. **End with `p "✅"`** as the final success indicator.

## demo-magic API

These are the functions available from `bin/demo-magic.sh`:

| Function | Behavior | Use for |
|----------|----------|---------|
| `p "text"` | Print text, wait for ENTER | Narrative, section headers, explanations |
| `pe "command"` | Print command, wait for ENTER, then execute and show output | kubectl, git, security tool commands |
| `pei "command"` | Print command and execute immediately (no wait) | Setup steps that don't need audience attention |
| `cmd` | Interactive mode — user types commands | Rarely used in demos |

## Script Structure Template

```bash
#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

# Optional: set PROJECT_ROOT for Makefile references
PROJECT_ROOT="$(cd ../.. && pwd)"

# Optional: prerequisite checks
if ! command -v some-tool &>/dev/null; then
    echo "❌ some-tool n'est pas installé."
    exit 1
fi

p "Titre principal de la démo"

p "1. Première étape — description en français"
pe "kubectl get pods -n ci"

p "2. Deuxième étape"
pe "some-command --flag value"

p "→ Explication du résultat"

# Inline YAML generation for test resources
cat > /tmp/demo-resource.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
  namespace: ci
YAML

pe "kubectl apply -f /tmp/demo-resource.yaml"

# Cleanup
pe "kubectl delete -f /tmp/demo-resource.yaml 2>/dev/null || true"

p "✅"
```

## Patterns to Follow

### Keep comments to the minimum
Keep your comments to a strict minimum. 
When a `pe` command output is explicit enough, there is no need to add comments after it.

#### Result commentary
After a `pe` command, When further explanations of results are necessary, use `p "→ Explication"` to explain what the audience just saw.

### Numbered sections
Use `p "N. Description en français"` for each major step. This gives the audience a sense of progression.

### Don't add line breaks
Don't use `p ""`. It just waists time.

### Multi-phase demos
For before/after comparisons (common in security demos), use labeled phases:
```bash
p "  PHASE 1 — AVANT : Description"
# ... vulnerable state commands ...

p "  PHASE 2 — Application des défenses"
# ... apply security measures ...

p "  PHASE 3 — APRÈS : Vérification"
# ... verify improvements ...
```

### Dynamic values
Extract values from the cluster for use in later commands:
```bash
POD_NAME=$(kubectl get pods -n ci -l app=victim -o name 2>/dev/null | head -1)
if [ -z "$POD_NAME" ]; then
    echo "⚠ Aucun pod trouvé."
else
    pe "kubectl describe ${POD_NAME} -n ci"
fi
```

### Inline YAML for test resources
When creating Kubernetes resources for demo purposes, use heredocs to `/tmp/`:
```bash
cat > /tmp/demo-test.yaml <<'YAML'
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: test-demo
  namespace: ci
spec:
  # ...
YAML
pe "kubectl create -f /tmp/demo-test.yaml"
```
Use `<<'YAML'` (single-quoted delimiter) when the content has no variable substitution. Use `<<YAML` (unquoted) when you need to interpolate shell variables inside the YAML.

### Error handling
Use `|| true` for commands that might fail but shouldn't stop the demo:
```bash
pe "kubectl delete pipelinerun old-run -n ci 2>/dev/null || true"
```

### Makefile integration
Reference Makefile targets when they exist:
```bash
pe "make -C ${PROJECT_ROOT} setup-ci-pr-pipeline-secure"
```

### Next-step pointers
If the demo is part of a sequence, point to the next script:
```bash
p "Prochaine étape : Kyverno → ./kyverno-demo.sh"
```

### Cleanup
Clean up temporary files and test resources at the end:
```bash
pe "kubectl delete -f /tmp/demo-resource.yaml 2>/dev/null || true"
rm -rf /tmp/demo-temp-dir
```

## Emoji Convention

| Emoji | Meaning |
|-------|---------|
| ✅ | Success / demo complete |
| ⚠ | Warning (non-fatal issue) |
| ❌ | Error / prerequisite missing |
| → | Result explanation |

## File Placement

Demo scripts go in the challenge folder they belong to:
- `challenges/challenge1/` — Token theft demos (scorecard, kubescape, kyverno)
- `challenges/challenge2/` — Container layer leak demos (filter-repo, scanning)
- `challenges/challenge3/` — Base image poisoning demos
- `challenges/challenge4/` — GitOps compromise demos

Name the script `<tool-or-topic>-demo.sh` (e.g., `trivy-demo.sh`, `kubescape-demo.sh`).

Make the script executable after creating it: `chmod +x <script-name>`.

## Example: Security Scanning Demo

```bash
#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

PROJECT_ROOT="$(cd ../.. && pwd)"

if ! command -v trivy &>/dev/null; then
    echo "❌ trivy n'est pas installé."
    exit 1
fi

p "Trivy — Scan de vulnérabilités sur les images de la pipeline"

p "1. Scanner l'image construite par la pipeline vulnérable"
IMAGE="localhost:30000/victim-app:latest"
pe "trivy image --severity HIGH,CRITICAL ${IMAGE}"

p "→ Trivy détecte les vulnérabilités critiques dans l'image"

p "2. Scanner les secrets dans les couches de l'image"
pe "trivy image --scanners secret ${IMAGE}"

p "→ Des secrets ont été trouvés dans les couches intermédiaires"

p "3. Générer un rapport SBOM au format CycloneDX"
pe "trivy image --format cyclonedx --output /tmp/sbom.json ${IMAGE}"
pe "cat /tmp/sbom.json | jq '.components | length'"

p "→ Le SBOM liste tous les composants de l'image"

rm -f /tmp/sbom.json

p "✅"
```
