#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

p "git-filter-repo — Nettoyage des secrets dans l'historique Git"
p "Référence : https://github.com/newren/git-filter-repo"

p "=== Prérequis : git-filter-repo doit être installé (brew ou dnf)==="
pe "git filter-repo --version"

WORK_DIR=$(mktemp -d)

p "1. Cloner le dépôt depuis Gitea"
pe "git clone http://sc-admin:SecurePass123\!@gitea.sc.local:30080/sc-admin/recipe-api ${WORK_DIR}/recipe-api"

cd "${WORK_DIR}/recipe-api"

p "2. Le fichier .env.production existe dans l'historique"
pe "git log --all --full-history -- .env.production --oneline"

# p "3. Afficher le contenu du fichier dans le commit initial"
# INITIAL_COMMIT=$(git log --reverse --format=%H | head -1)
# pe "git show ${INITIAL_COMMIT}:.env.production"

# p "⚠  ARGOCD_AUTH_TOKEN, REGISTRY_PASSWORD, et d'autres secrets sont exposés"

p "3. Créer une sauvegarde avant la réécriture"
pe "tar -czf ${WORK_DIR}/recipe-api-backup.tar.gz -C ${WORK_DIR} recipe-api"
pe "ls -lh ${WORK_DIR}/recipe-api-backup.tar.gz"

p "4. Exécuter git filter-repo pour supprimer .env.production de TOUT l'historique"
p "→ --sensitive-data-removal : mode dédié au nettoyage de données sensibles"
p "→ --invert-paths --path .env.production : exclure ce fichier de tous les commits"
pe "git filter-repo --sensitive-data-removal --invert-paths --path .env.production"

p "5. Vérifier que le fichier n'existe plus dans aucun commit"
pe "git log --all --full-history -- .env.production"

# p "→ Aucun résultat : le fichier a été complètement supprimé de l'historique"

# p "7. Vérifier que le secret ARGOCD_AUTH_TOKEN n'apparaît plus"
# pe "git log --all --full-history -S 'ARGOCD_AUTH_TOKEN' --oneline"

# p "→ Aucun résultat : les secrets ont été purgés de tous les commits"

p "6. Vérifier le contenu du premier commit réécrit"
FIRST_COMMIT=$(git log --reverse --format=%H | head -1)
pe "git show --stat ${FIRST_COMMIT}"

p "→ .env.production n'apparaît plus dans le commit"

p "9. Référence à .env.production dans .gitignore (inoffensif)"
pe "git diff ${FIRST_COMMIT} HEAD -- .gitignore"

p "=== ÉTAPES SUIVANTES ==="
p "Pour propager le nettoyage au serveur, il faudra :  git push --force --mirror origin"
p "⚠  Tous les collaborateurs doivent re-cloner le dépôt après le force push"
p "⚠  Les images Docker construites à partir de l'ancien historique contiennent encore les secrets"
p "⚠  Il faut donc reconstruire et re-pousser les images après le nettoyage"
p "⚠  Contacter les administrateurs du serveur pour purger les anciennes références"

rm -rf ${WORK_DIR}

p "✅"
