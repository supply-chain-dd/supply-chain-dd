#!/bin/bash

########################
# include the magic
########################
. ../../bin/demo-magic.sh

# hide the evidence
clear

# Pre-requisites: sherine-k/gophers-api GH repo under ~/go/src/github.com/scraly/gophers-api

cd ~/go/src/github.com/scraly/gophers-api

git checkout main
p "Workflow validate.yml sur branche main"
pe "head -n 10 .github/workflows/validate.yml"

p "Modification de l'évènement de déclenchement: pull_request_target"
p "(sur la branche test_pr_target)"
pe "git diff test_pr_target"
pe "git checkout test_pr_target"
p "COMMIT_ID=git rev-parse --short HEAD"
COMMIT_ID=`git rev-parse --short HEAD`
pe "scorecard --repo=github.com/sherine-k/gophers-api --checks=Dangerous-Workflow --commit $COMMIT_ID"

p "Modification de l'origine du code source"
p "(sur la branche test_pr_target*2*)"
pe "git diff test_pr_target2"
pe "git checkout test_pr_target2"
p "COMMIT_ID=git rev-parse --short HEAD"
COMMIT_ID=`git rev-parse --short HEAD`
pe "scorecard --repo=github.com/sherine-k/gophers-api --checks=Dangerous-Workflow --commit $COMMIT_ID"
p "✅"

