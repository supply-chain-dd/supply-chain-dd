#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

PROJECT_ROOT="$(cd ../.. && pwd)"

if ! kubectl kubescape version >/dev/null 2>&1; then
    echo "❌ kubectl kubescape n'est pas installé. Exécuter: make install-kubescape"
    exit 1
fi

p "Kubescape - Scan ciblé sur le workload de la pipeline VULNÉRABLE"

p "1. Scan du pod quality-check de la pipeline vulnérable"
VULN_POD=$(kubectl get pods -n ctf-challenge -l tekton.dev/pipelineTask=run-quality-checks -o name 2>/dev/null | head -1)
if [ -z "$VULN_POD" ]; then
    echo "⚠ Aucun pod quality-check trouvé. Utilisation du scan C-0015 sur le namespace."
    pe "kubectl kubescape scan control C-0015 -v --include-namespaces ctf-challenge"
else
    pe "kubectl kubescape scan workload ${VULN_POD} --namespace ctf-challenge"
fi

p "2. Contrôle C-0260 : quels pods n'ont pas de NetworkPolicy ?"
pe "kubectl kubescape scan control C-0260 -v --include-namespaces ctf-challenge"

p "3. Application de la pipeline SÉCURISÉE + Network Policies"
pe "make -C ${PROJECT_ROOT} setup-ctf-challenge-secure"
pe "kubectl apply -f security/network-policies/tekton-egress-restriction.yaml"

p "Suppression des anciens PipelineRuns"
pe "kubectl delete pipelineruns --all -n ctf-challenge"

p "Création d'un PipelineRun avec le SA pr-pipeline-readonly"

PR_SHA=$(kubectl get pipelinerun -n ctf-challenge -o jsonpath='{.items[0].spec.params[?(@.name=="pr-sha")].value}' 2>/dev/null || echo "main")
PR_URL=$(kubectl get pipelinerun -n ctf-challenge -o jsonpath='{.items[0].spec.params[?(@.name=="pr-repo-url")].value}' 2>/dev/null || echo "http://gitea-http.gitea.svc.cluster.local:3000/hacker/recipe-api.git")

cat > /tmp/kubescape-demo-pipelinerun.yaml <<YAML
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: pr-quality-check-secure-test
  namespace: ctf-challenge
spec:
  serviceAccountName: pr-pipeline-readonly
  pipelineRef:
    name: pr-quality-check-pipeline
  params:
    - name: pr-repo-url
      value: "${PR_URL}"
    - name: pr-sha
      value: "${PR_SHA}"
    - name: pr-number
      value: "1"
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
YAML

pe "kubectl create -f /tmp/kubescape-demo-pipelinerun.yaml"

p "Attente de la fin du PipelineRun..."
kubectl wait --for=condition=Succeeded pipelinerun/pr-quality-check-secure-test -n ctf-challenge --timeout=120s 2>/dev/null || true

p "4. Scan du pod quality-check de la pipeline SÉCURISÉE"
SECURE_POD=$(kubectl get pods -n ctf-challenge -l tekton.dev/pipelineTask=run-quality-checks -o name 2>/dev/null | head -1)
if [ -z "$SECURE_POD" ]; then
    echo "⚠ Aucun pod quality-check trouvé."
else
    pe "kubectl kubescape scan workload ${SECURE_POD} --namespace ctf-challenge"
fi

p "C-0034 (Automatic mapping of service account) reste en échec :"
p "Tekton monte automatiquement le token du SA dans chaque pod."
p "On ne peut pas désactiver automountServiceAccountToken sans casser Tekton."
p "→ C'est pour ça que le RBAC et les NetworkPolicies sont indispensables :"
p "  le token existe, mais il ne peut ni lire les secrets (RBAC) ni les exfiltrer (NetworkPolicy)"

p "5. Re-vérification C-0260 après application des NetworkPolicies"
pe "kubectl kubescape scan control C-0260 -v --include-namespaces ctf-challenge"

p "Prochaine étape : Kyverno → ./kyverno-demo.sh"
p "✅"
