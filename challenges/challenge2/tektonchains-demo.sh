#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COSIGN_PUB="${REPO_ROOT}/cosign.pub"
REGISTRY_CA="${REPO_ROOT}/setup/certs/registry.crt"
REGISTRY_URL="localhost:30000"
IMAGE_NAME="recipe-api"
IMAGE_TAG="v2.0"
IMAGE_REF="${REGISTRY_URL}/${IMAGE_NAME}:${IMAGE_TAG}"

if ! command -v cosign &>/dev/null; then
    echo "❌ cosign n'est pas installé. Voir: https://docs.sigstore.dev/cosign/installation/"
    exit 1
fi

if ! command -v tkn &>/dev/null; then
    echo "⚠  tkn CLI non trouvé. Installer avec: make -C ${REPO_ROOT} install-tkn"
    echo "   Les logs de la pipeline ne seront pas affichés en temps réel."
fi

p "=== Tekton Chains — Signature d'images et provenance SLSA ==="
p "Tekton Chains est un contrôleur Kubernetes qui surveille les PipelineRuns."
p "Après chaque exécution, il signe automatiquement les images et génère"
p "une attestation de provenance SLSA au format in-toto."

# ============================================================================
# SECTION 1 — Installation
# ============================================================================

p "  SECTION 1 — Installation de Tekton Chains"

if ! kubectl get namespace tekton-chains &>/dev/null || \
   [ "$(kubectl get pods -n tekton-chains --no-headers 2>/dev/null | wc -l)" -eq 0 ]; then
    p "Tekton Chains n'est pas encore déployé — installation en cours..."
    pe "make -C ${REPO_ROOT} setup-tektonchains"
else
    p "Tekton Chains est déjà installé"
fi

pe "kubectl get pods -n tekton-chains"
p "→ Le contrôleur tekton-chains-controller surveille tous les TaskRuns et PipelineRuns"

pe "kubectl get deployment tekton-chains-controller -n tekton-chains -o jsonpath='{.spec.template.spec.containers[0].image}' && echo"

# ============================================================================
# SECTION 2 — Configuration
# ============================================================================

p "  SECTION 2 — Configuration de Tekton Chains"
p "Toute la configuration se fait dans le ConfigMap 'chains-config'"

pe "kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data}' | jq ."
p "→ artifacts.pipelinerun.format: in-toto — format d'attestation standard SLSA"
p "→ artifacts.pipelinerun.storage: oci — stockage dans le registre OCI"
p "→ artifacts.pipelinerun.enable-deep-inspection: true — inspecte chaque TaskRun"
p "→ artifacts.oci.format: simplesigning — format de signature cosign"
p "→ artifacts.oci.signer: x509 — clé de signature locale (pas Fulcio/OIDC)"

# ============================================================================
# SECTION 3 — Clé de signature
# ============================================================================

p "  SECTION 3 — Clé de signature cosign"
# p "Tekton Chains utilise une paire de clés cosign dans un Secret Kubernetes"

pe "kubectl get secret signing-secrets -n tekton-chains -o jsonpath='{.data}' | jq 'keys'"
# p "→ cosign.key : clé privée chiffrée (utilisée par le contrôleur pour signer)"
# p "→ cosign.password : mot de passe de la clé privée"
# p "→ cosign.pub : clé publique (utilisée pour vérifier les signatures)"

p "La clé publique est aussi sauvegardée localement :"
pe "cat ${COSIGN_PUB}"

p "Alternatives pour la production :"
p "  - Fulcio + OIDC : signature keyless via identité (signers.x509.fulcio.enabled: true)"
p "  - KMS : clé stockée dans un HSM ou service cloud (AWS KMS, GCP KMS, Vault)"

# ============================================================================
# SECTION 4 — Intégration dans la pipeline
# ============================================================================

p "  SECTION 4 — Intégration dans la pipeline"
p "Chains surveille les TaskRuns qui émettent deux résultats : IMAGE_URL et IMAGE_DIGEST"

pe "kubectl get task push-container-image-with-chains -n ctf-challenge -oyaml"

# p "Comparaison des résultats des deux pipelines :"
# p "push-build-pipeline-secure (sans Chains) :"
# pe "kubectl get pipeline push-build-pipeline-secure -n ctf-challenge -o jsonpath='{.spec.results[*].name}' && echo"

# p "push-build-pipeline-with-chains (avec Chains) :"
pe "kubectl get pipeline push-build-pipeline-with-chains -n ctf-challenge -o jsonpath='{.spec.results[*].name}' && echo"
p "→ CHAINS-GIT_COMMIT et CHAINS-GIT_URL sont des type hints pour la provenance SLSA"
p "→ Chains les inclut automatiquement dans les 'materials' de l'attestation"

# ============================================================================
# SECTION 5 — Exécution de la pipeline
# ============================================================================

p "  SECTION 5 — Exécution de la pipeline"
p "Déclenchons la pipeline avec Chains et observons les artefacts générés"

pe "kubectl create -f ${SCRIPT_DIR}/tekton/manual-pipelinerun-with-chains.yaml"

sleep 3
LATEST_PR=$(kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
# p "→ PipelineRun créé : ${LATEST_PR}"

p "Suivi des logs en temps réel..."
if command -v tkn &>/dev/null; then
    pei "tkn pr logs -f ${LATEST_PR} -n ctf-challenge"
else
    p "tkn non disponible — attente de la fin de la pipeline..."
    kubectl wait --for=condition=Succeeded pipelinerun/${LATEST_PR} -n ctf-challenge --timeout=600s 2>/dev/null || true
fi

pe "kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.status.conditions[0].reason}' && echo"

p "La pipeline est terminée — Tekton Chains signe maintenant l'image en arrière-plan"
p "Attente de la signature par Chains..."

for i in $(seq 1 12); do
    SIGNED=$(kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null)
    [ "$SIGNED" = "true" ] && break
    sleep 5
done

if [ "$SIGNED" != "true" ]; then
    p "⚠  Chains n'a pas encore signé — les vérifications suivantes pourraient échouer"
fi

# ============================================================================
# SECTION 6 — Artefacts générés par Tekton Chains
# ============================================================================

p "  SECTION 6 — Artefacts générés par Tekton Chains"

p "6.1 Annotations Chains sur le PipelineRun"
pe "kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.metadata.annotations}' | jq '{\"chains.tekton.dev/signed\": .[\"chains.tekton.dev/signed\"], \"chains.tekton.dev/transparency\": .[\"chains.tekton.dev/transparency\"]}'"
p "→ chains.tekton.dev/signed: true — Chains a signé ce PipelineRun"

p "6.2 Résultats IMAGE_URL et IMAGE_DIGEST de la pipeline"
pe "kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.status.results}' | jq '.[] | select(.name==\"IMAGE_URL\" or .name==\"IMAGE_DIGEST\") | {name, value}'"

IMAGE_DIGEST=$(kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)

p "6.3 Vérification de la signature de l'image avec cosign"
pe "cosign verify --insecure-ignore-tlog --key ${COSIGN_PUB} --registry-cacert=${REGISTRY_CA} ${IMAGE_REF} 2>&1 | head -20"
p "→ La signature cosign est valide — l'image a été signée par Tekton Chains"

p "6.4 Vérification de l'attestation de provenance SLSA"
pe "cosign verify-attestation --insecure-ignore-tlog --key ${COSIGN_PUB} --type slsaprovenance --registry-cacert=${REGISTRY_CA} ${IMAGE_REF} 2>&1 | head -5"
p "→ L'attestation de provenance SLSA est valide et signée"

p "6.5 Contenu de l'attestation de provenance"
pe "cosign verify-attestation --insecure-ignore-tlog --key ${COSIGN_PUB} --type slsaprovenance --registry-cacert=${REGISTRY_CA} ${IMAGE_REF} 2>/dev/null | jq -r '.payload' | base64 -d | jq '{predicateType, builder: .predicate.builder, materials: .predicate.materials}'"
p "→ predicateType: provenance SLSA au format in-toto"
p "→ builder.id: identifie Tekton Chains comme builder"
p "→ materials: source git (URL + commit) utilisée pour le build"

p "6.6 Vue d'ensemble des artefacts OCI"
pe "cosign tree --registry-cacert=${REGISTRY_CA} ${IMAGE_REF} 2>/dev/null || echo 'cosign tree non disponible'"
p "→ .sig : signature cosign de l'image"
p "→ .att : attestation de provenance SLSA signée"

# ============================================================================
# RÉSUMÉ
# ============================================================================

# p "=== RÉSUMÉ ==="
# p "1. Tekton Chains s'installe comme un contrôleur dans le namespace tekton-chains"
# p "2. La configuration se fait via le ConfigMap chains-config (format, stockage, signer)"
# p "3. La clé de signature cosign est stockée dans le Secret signing-secrets"
# p "4. Les tasks doivent émettre IMAGE_URL et IMAGE_DIGEST pour déclencher la signature"
# p "5. Après chaque PipelineRun, Chains génère automatiquement :"
# p "   - Une signature cosign de l'image (.sig)"
# p "   - Une attestation de provenance SLSA (.att)"
# p "6. Les artefacts sont vérifiables avec cosign verify et cosign verify-attestation"

p "✅"
