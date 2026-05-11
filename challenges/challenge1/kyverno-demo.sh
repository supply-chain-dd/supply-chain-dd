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

p "2. Application des politiques Kyverno"
pe "kubectl apply -f security/kyverno-policies/"
pe "kubectl get clusterpolicy"

p "Politique principale (mode Enforce) :"
pe "kubectl get clusterpolicy restrict-tekton-pr-pipelines -o yaml | head -50"

p "3. Test : PipelineRun SANS serviceAccountName → BLOQUÉ"

cat > /tmp/kyverno-demo-vulnerable.yaml <<'YAML'
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: test-vulnerable-pr
  namespace: ctf-challenge
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

pe "kubectl create -f /tmp/kyverno-demo-vulnerable.yaml 2>&1 || true"

p "4. Test : PipelineRun avec pr-pipeline-readonly → AUTORISÉ"
pe "kubectl apply -f security/rbac/minimal-serviceaccounts.yaml"

cat > /tmp/kyverno-demo-secure.yaml <<'YAML'
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: test-secure-pr
  namespace: ctf-challenge
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

pe "kubectl create -f /tmp/kyverno-demo-secure.yaml 2>&1 || true"

p "5. Rapports de politique Kyverno"
pe "kubectl get policyreport -A 2>/dev/null || echo 'Pas de rapports disponibles'"

p "Nettoyage"
pe "kubectl delete pipelinerun test-secure-pr -n ctf-challenge 2>/dev/null || true"

p "Prochaine étape : Network Policies + RBAC → ./network-policy-demo.sh"
p "✅"
