#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

p "Network Policies + RBAC - Défense en profondeur"
p "⚠ Note : kindnetd n'applique pas les NetworkPolicies. Calico/Cilium requis pour l'enforcement."

p "1. État actuel : aucune NetworkPolicy"
pe "kubectl get networkpolicy -n ctf-challenge"

p "2. Test AVANT : accès externe depuis un pod"
pe "kubectl run -n ctf-challenge netpol-test-before --image=busybox:1.36 --restart=Never --rm -i --timeout=30s -- wget -q -O- --timeout=5 http://example.com 2>&1 | head -5 || true"

p "3. Application des Network Policies"
pe "kubectl apply -f security/network-policies/tekton-egress-restriction.yaml"
pe "kubectl get networkpolicy -n ctf-challenge"

p "Politique principale :"
pe "kubectl describe networkpolicy ctf-challenge-egress-restriction -n ctf-challenge"

p "4. Test APRÈS : accès externe bloqué (timeout attendu)"
pe "kubectl run -n ctf-challenge netpol-test-after --image=busybox:1.36 --restart=Never --rm -i --timeout=30s -- wget -q -O- --timeout=5 http://example.com 2>&1 | head -5 || true"

p "5. Vérification : services internes toujours accessibles"
pe "kubectl run -n ctf-challenge netpol-test-internal --image=busybox:1.36 --restart=Never --rm -i --timeout=30s -- wget -q -O- --timeout=5 http://gitea-http.gitea.svc.cluster.local:3000/api/v1/version 2>&1 || true"

p "RBAC - Principe du moindre privilège"
pe "kubectl apply -f security/rbac/minimal-serviceaccounts.yaml"

p "SA 'default' (vulnérable) - peut lire les secrets :"
pe "kubectl auth can-i get secrets --as=system:serviceaccount:ctf-challenge:default -n ctf-challenge"

p "SA 'pr-pipeline-readonly' (sécurisé) - NE PEUT PAS lire les secrets :"
pe "kubectl auth can-i get secrets --as=system:serviceaccount:ctf-challenge:pr-pipeline-readonly -n ctf-challenge"

p "Détails du rôle pr-pipeline-minimal :"
pe "kubectl describe role pr-pipeline-minimal -n ctf-challenge"

p "✅"
