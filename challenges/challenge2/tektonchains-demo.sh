#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY_CA="${REPO_ROOT}/setup/certs/registry.crt"
REGISTRY_URL="localhost:30000"
IMAGE_NAME="recipe-api"
IMAGE_TAG="v2.0"
IMAGE_REF="${REGISTRY_URL}/${IMAGE_NAME}:${IMAGE_TAG}"
REKOR_NODE_PORT="${REKOR_NODE_PORT:-30006}"
TUF_NODE_PORT="${TUF_NODE_PORT:-30007}"
REKOR_URL_LOCAL="http://localhost:${REKOR_NODE_PORT}"
TUF_MIRROR_LOCAL="http://localhost:${TUF_NODE_PORT}"

if ! command -v cosign &>/dev/null; then
    echo "cosign n'est pas installe. Voir: https://docs.sigstore.dev/cosign/installation/"
    exit 1
fi

if ! command -v tkn &>/dev/null; then
    echo "tkn CLI non trouve. Installer avec: make -C ${REPO_ROOT} install-tkn"
    echo "   Les logs de la pipeline ne seront pas affiches en temps reel."
fi

cleanup() {
    [ -n "${TUF_ROOT_FILE:-}" ] && rm -f "${TUF_ROOT_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

p "=== Tekton Chains — Signature d'images et provenance SLSA ==="
p "Tekton Chains est un controleur Kubernetes qui surveille les PipelineRuns."
p "Apres chaque execution, il signe automatiquement les images et genere"
p "une attestation de provenance SLSA au format in-toto."

# ============================================================================
# SECTION 1 — Verification de l'installation
# ============================================================================

p "  SECTION 1 — Tekton Chains (pre-installe par setup-demo)"

pe "kubectl get pods -n tekton-chains"
p "Le controleur tekton-chains-controller surveille tous les TaskRuns et PipelineRuns"

pe "kubectl get deployment tekton-chains-controller -n tekton-chains -o jsonpath='{.spec.template.spec.containers[0].image}' && echo"

# ============================================================================
# SECTION 2 — Configuration
# ============================================================================

p "  SECTION 2 — Configuration de Tekton Chains"
p "Toute la configuration se fait dans le ConfigMap 'chains-config'"

pe "kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data}' | jq ."
p "artifacts.pipelinerun.format: in-toto — format d'attestation standard SLSA"
p "artifacts.pipelinerun.storage: oci — stockage dans le registre OCI"
p "artifacts.pipelinerun.enable-deep-inspection: true — inspecte chaque TaskRun"
p "artifacts.oci.format: simplesigning — format de signature cosign"
p "signers.x509.fulcio.enabled: true — signature keyless via Fulcio"
p "signers.x509.fulcio.address: http://fulcio.fulcio-system.svc — CA interne"
p "transparency.url: http://rekor.rekor-system.svc — log de transparence interne"

# ============================================================================
# SECTION 3 — Signature keyless via Fulcio
# ============================================================================

p "  SECTION 3 — Signature keyless via Fulcio"
p "Tekton Chains utilise un token OIDC projete pour s'authentifier aupres de Fulcio"
p "Fulcio emet un certificat ephemere lie a l'identite du ServiceAccount"

p "Token OIDC projete dans le controleur :"
pe "kubectl get deployment tekton-chains-controller -n tekton-chains -o jsonpath='{.spec.template.spec.volumes}' | jq '.[] | select(.name==\"oidc-info\")'"
p "audience: sigstore — Fulcio n'accepte que les tokens avec cette audience"

ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')
p "OIDC issuer du cluster : ${ISSUER}"
p "Identite du certificat : https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller"
p "Pas de cle privee a gerer — le certificat est ephemere (10 min)"

# ============================================================================
# SECTION 4 — Integration dans la pipeline
# ============================================================================

p "  SECTION 4 — Integration dans la pipeline"
p "Chains surveille les TaskRuns qui emettent deux resultats : IMAGE_URL et IMAGE_DIGEST"

pe "kubectl get task push-container-image-with-chains -n ctf-challenge -oyaml"

pe "kubectl get pipeline push-build-pipeline-with-chains -n ctf-challenge -o jsonpath='{.spec.results[*].name}' && echo"
p "CHAINS-GIT_COMMIT et CHAINS-GIT_URL sont des type hints pour la provenance SLSA"
p "Chains les inclut automatiquement dans les 'materials' de l'attestation"

# ============================================================================
# SECTION 5 — Execution de la pipeline
# ============================================================================

p "  SECTION 5 — Execution de la pipeline"
p "Declenchons la pipeline avec Chains et observons les artefacts generes"

pe "kubectl create -f ${SCRIPT_DIR}/tekton/manual-pipelinerun-with-chains.yaml"

sleep 3
LATEST_PR=$(kubectl get pipelineruns -n ctf-challenge --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

p "Suivi des logs en temps reel..."
if command -v tkn &>/dev/null; then
    pei "tkn pr logs -f ${LATEST_PR} -n ctf-challenge"
else
    p "tkn non disponible — attente de la fin de la pipeline..."
    kubectl wait --for=condition=Succeeded pipelinerun/${LATEST_PR} -n ctf-challenge --timeout=600s 2>/dev/null || true
fi

pe "kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.status.conditions[0].reason}' && echo"

p "La pipeline est terminee — Tekton Chains signe maintenant l'image en arriere-plan"
p "Attente de la signature par Chains..."

for i in $(seq 1 12); do
    SIGNED=$(kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null)
    [ "$SIGNED" = "true" ] && break
    sleep 5
done

if [ "$SIGNED" != "true" ]; then
    p "Chains n'a pas encore signe — les verifications suivantes pourraient echouer"
fi

# ============================================================================
# SECTION 6 — Artefacts generes par Tekton Chains
# ============================================================================

p "  SECTION 6 — Artefacts generes par Tekton Chains"

p "6.1 Annotations Chains sur le PipelineRun"
pe "kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.metadata.annotations}' | jq '{\"chains.tekton.dev/signed\": .[\"chains.tekton.dev/signed\"], \"chains.tekton.dev/transparency\": .[\"chains.tekton.dev/transparency\"]}'"
p "chains.tekton.dev/signed: true — Chains a signe ce PipelineRun"

p "6.2 Resultats IMAGE_URL et IMAGE_DIGEST de la pipeline"
pe "kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.status.results}' | jq '.[] | select(.name==\"IMAGE_URL\" or .name==\"IMAGE_DIGEST\") | {name, value}'"

IMAGE_DIGEST=$(kubectl get pipelinerun ${LATEST_PR} -n ctf-challenge -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null)

p "6.3 Verification keyless de la signature de l'image avec cosign"
p "Initialisation du TUF root pour faire confiance au Fulcio/Rekor local"
TUF_ROOT_FILE=$(mktemp)
kubectl get configmap sigstore-tuf-root -n ctf-challenge -o jsonpath='{.data.root\.json}' > "${TUF_ROOT_FILE}"
pe "cosign initialize --mirror=${TUF_MIRROR_LOCAL} --root=${TUF_ROOT_FILE}"

pe "cosign verify \
  --certificate-identity=https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller \
  --certificate-oidc-issuer=${ISSUER} \
  --rekor-url=${REKOR_URL_LOCAL} \
  --insecure-ignore-sct \
  --registry-cacert=${REGISTRY_CA} \
  ${IMAGE_REF} 2>&1 | head -20"
p "La signature keyless est valide — l'image a ete signee par Tekton Chains via Fulcio"

p "6.4 Verification de l'attestation de provenance SLSA"
pe "cosign verify-attestation \
  --certificate-identity=https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller \
  --certificate-oidc-issuer=${ISSUER} \
  --rekor-url=${REKOR_URL_LOCAL} \
  --insecure-ignore-sct \
  --type slsaprovenance \
  --registry-cacert=${REGISTRY_CA} \
  ${IMAGE_REF} 2>&1 | head -5"
p "L'attestation de provenance SLSA est valide et signee"

p "6.5 Contenu de l'attestation de provenance"
pe "cosign verify-attestation \
  --certificate-identity=https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller \
  --certificate-oidc-issuer=${ISSUER} \
  --rekor-url=${REKOR_URL_LOCAL} \
  --insecure-ignore-sct \
  --type slsaprovenance \
  --registry-cacert=${REGISTRY_CA} \
  ${IMAGE_REF} 2>/dev/null | jq -r '.payload' | base64 -d | jq '{predicateType, builder: .predicate.builder, materials: .predicate.materials}'"
p "predicateType: provenance SLSA au format in-toto"
p "builder.id: identifie Tekton Chains comme builder"
p "materials: source git (URL + commit) utilisee pour le build"

p "6.6 Vue d'ensemble des artefacts OCI"
pe "cosign tree --registry-cacert=${REGISTRY_CA} ${IMAGE_REF} 2>/dev/null || echo 'cosign tree non disponible'"
p ".sig : signature cosign de l'image"
p ".att : attestation de provenance SLSA signee"

p ""
