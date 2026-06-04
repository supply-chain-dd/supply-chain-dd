#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

if ! command -v sourcetool &>/dev/null; then
    echo "❌ sourcetool n'est pas installé."
    echo "   Installer depuis: https://github.com/slsa-framework/source-tool"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "❌ jq n'est pas installé."
    exit 1
fi

REPO="supply-chain-dd/supply-chain-dd"
BRANCH="main"

p "=== SLSA Source Tool - Vérification de la provenance du code source ==="


p "1. Vérifier le statut du dépôt sur la branche $BRANCH"
pe "sourcetool status ${REPO}@${BRANCH}"

p "2. Récupérer le dernier commit sur $BRANCH"
pe "git fetch origin refs/notes/commits:refs/notes/commits"
pe "COMMIT_ID=\$(git rev-parse origin/${BRANCH})"
COMMIT_ID=$(git rev-parse origin/${BRANCH})

p "3. Afficher l'attestation SLSA stockée dans les git notes"
pe "git notes show ${COMMIT_ID} | jq"

p "4. Vérifier la provenance du commit avec sourcetool"
pe "sourcetool verifycommit ${REPO}@${BRANCH}"

p "✅"
