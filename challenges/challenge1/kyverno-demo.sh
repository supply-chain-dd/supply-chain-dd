#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

p "Kyverno - Contrôle d'admission des pipelines Tekton"

p "1. Vérification de Kyverno"
pe "kubectl get pods -n kyverno"
pe "kubectl get clusterpolicy"

p "2. Application de la politique block-dangerous-task-commands (mode Audit)"
p "→ Détecte les commandes dangereuses (go run, curl|bash, scripts repo)"
pe "kubectl apply -f security/kyverno-policies/block-dangerous-commands.yaml"
pe "kubectl get clusterpolicy block-dangerous-task-commands -o yaml"

p "3. PolicyReports : le scan de fond a détecté des commandes dangereuses dans les Tasks"
pe "kubectl get policyreport -n ci -o json | jq '.items[] | select(.summary.fail > 0) | {task: .scope.name, kind: .scope.kind, failures: [.results[] | select(.result == \"fail\") | {rule, message}]}'"

p "4. Application de la politique restrict-tekton-pr-pipelines (mode Enforce)"
p "→ Bloque la création de PipelineRun/TaskRun avec un SA non autorisé"
pe "kubectl apply -f security/kyverno-policies/restrict-tekton-serviceaccounts.yaml"
pe "kubectl get clusterpolicy restrict-tekton-pr-pipelines -o yaml"

p "5. Test : PipelineRun SANS serviceAccountName → BLOQUÉ par Kyverno"

cat > /tmp/kyverno-demo-blocked.yaml <<'YAML'
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: test-blocked-pr
  namespace: ci
spec:
  pipelineRef:
    name: pr-quality-check-pipeline
  params:
    - name: pr-repo-url
      value: "http://gitea-http.gitea.svc.cluster.local:3000/hacker/recipe-api.git"
    - name: pr-sha
      value: "main"
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

pe "kubectl create -f /tmp/kyverno-demo-blocked.yaml 2>&1 || true"

p "→ Kyverno a bloqué la création : le SA 'default' n'est pas autorisé"

p "6. Test : PipelineRun avec pr-pipeline-readonly → AUTORISÉ"

cat > /tmp/kyverno-demo-allowed.yaml <<'YAML'
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: test-allowed-pr
  namespace: ci
spec:
  serviceAccountName: pr-pipeline-readonly
  pipelineRef:
    name: pr-quality-check-pipeline
  params:
    - name: pr-repo-url
      value: "http://gitea-http.gitea.svc.cluster.local:3000/hacker/recipe-api.git"
    - name: pr-sha
      value: "main"
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

pe "kubectl create -f /tmp/kyverno-demo-allowed.yaml 2>&1 || true"
p "→ Création autorisée avec le SA pr-pipeline-readonly"

# Nettoyage
kubectl delete clusterpolicy restrict-tekton-pr-pipelines block-dangerous-task-commands 2>/dev/null || true
kubectl delete pipelinerun test-allowed-pr -n ci 2>/dev/null || true

p "✅"
