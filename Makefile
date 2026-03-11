.PHONY: help setup setup-kind setup-gitea setup-tekton setup-ctf-challenge verify verify-ctf status clean

CLUSTER_NAME ?= ctf-cluster
GITEA_VERSION ?= 10.6.1
TEKTON_PIPELINE_VERSION ?= v0.53.0

help: ## Display this help message
	@echo "Supply Chain CTF Environment - Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: setup-kind setup-gitea setup-tekton verify ## Complete setup (KinD cluster + Gitea + act_runner + verification)
# I took away setup-act-runner from setup
# PS: in case of problems with file watching (e.g. "too many open files" errors), you may need to increase inotify limits on your host machine:
# sudo sysctl fs.inotify.max_user_watches=524288
# sudo sysctl fs.inotify.max_user_instances=512

setup-kind: ## Create KinD cluster
	@cd setup && ./scripts/setup-kind.sh

setup-gitea: ## Install Gitea via Helm
	@cd setup && ./scripts/setup-gitea.sh

# setup-act-runner: ## Install Gitea Actions Runner
# 	@cd setup && ./scripts/setup-act-runner.sh

setup-tekton: ## Install Tekton Pipelines and Triggers
	@cd setup && ./scripts/setup-tekton.sh

setup-ctf-challenge: ## Install Tekton CTF challenge resources
	@echo "Installing Tekton CTF Challenge..."
	@kubectl create namespace ctf-challenge 2>/dev/null || true
	@kubectl apply -f tekton/triggers/vulnerable-eventlistener.yaml
	@kubectl apply -f tekton/tasks/supporting-tasks.yaml
	@kubectl apply -f tekton/tasks/vulnerable-quality-check-task.yaml
	@kubectl apply -f tekton/pipelines/vulnerable-pr-quality-pipeline.yaml
	@echo ""
	@echo "Creating CTF flag secret..."
	@kubectl create secret generic ctf-flag \
		--from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
		-n default --dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "✓ CTF Challenge installed successfully"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Review the challenge guide: tekton/challenges/CTF-CHALLENGE-GUIDE.md"
	@echo "  2. Setup victim repository: tekton/challenges/victim-repo-sample/"
	@echo "  3. Test the challenge: make verify-ctf"

verify: ## Verify environment is working correctly
	@echo "Verifying CTF environment..."
	@echo ""
	@echo "Cluster Info:"
	@kubectl cluster-info
	@echo ""
	@echo "Gitea Pods:"
	@kubectl get pods -n gitea
	@echo ""
	@echo "Gitea Service:"
	@kubectl get svc -n gitea
# 	@echo ""
# 	@echo "Act Runner:"
# 	@kubectl get pods -n gitea -l app=act-runner 2>/dev/null || echo "  Act runner not installed"
	@echo ""
	@echo "Helm Releases:"
	@helm list -n gitea
	@echo ""
	@echo "✓ Environment verification complete"

status: ## Show environment status
	@echo "CTF Environment Status"
	@echo "======================"
	@echo ""
	@echo "KinD Clusters:"
	@kind get clusters || echo "  No clusters found"
	@echo ""
	@echo "Kubernetes Context:"
	@kubectl config current-context || echo "  No context set"
	@echo ""
	@echo "Cluster Nodes:"
	@kubectl get nodes 2>/dev/null || echo "  Cluster not running"
	@echo ""
	@echo "Gitea Pods:"
	@kubectl get pods -n gitea 2>/dev/null || echo "  Gitea not installed"
	@echo ""
	@echo "Gitea Service:"
	@kubectl get svc -n gitea 2>/dev/null || echo "  Gitea not installed"
	@echo ""
# 	@echo "Act Runner:"
# 	@kubectl get pods -n gitea -l app=act-runner 2>/dev/null || echo "  Act runner not installed"
	@echo ""
	@echo "Access Gitea at: http://localhost:30002"

verify-ctf: ## Verify Tekton CTF challenge installation
	@echo "Verifying Tekton CTF Challenge..."
	@echo ""
	@echo "Tekton Pipelines:"
	@kubectl get pods -n tekton-pipelines 2>/dev/null || echo "  ❌ Tekton not installed (run: make setup-tekton)"
	@echo ""
	@echo "CTF Pipeline:"
	@kubectl get pipeline pr-quality-check-pipeline 2>/dev/null || echo "  ❌ Pipeline not found (run: make setup-ctf-challenge)"
	@echo ""
	@echo "CTF Tasks:"
	@kubectl get task quality-check-task git-clone print-info print-results 2>/dev/null || echo "  ❌ Tasks not found"
	@echo ""
	@echo "EventListener:"
	@kubectl get eventlistener pr-quality-check-listener 2>/dev/null || echo "  ❌ EventListener not found"
	@echo ""
	@echo "CTF Flag Secret:"
	@kubectl get secret ctf-flag 2>/dev/null && echo "  ✓ Flag secret exists" || echo "  ❌ Flag secret not found"
	@echo ""
	@echo "ServiceAccounts:"
	@kubectl get sa tekton-triggers-sa pipeline-sa 2>/dev/null || echo "  ❌ ServiceAccounts not found"
	@echo ""
	@echo "✓ Verification complete"
	@echo ""
	@echo "To test the challenge:"
	@echo "  tkn pipeline start pr-quality-check-pipeline \\"
	@echo "    --param pr-repo-url=https://github.com/example/repo.git \\"
	@echo "    --param pr-sha=main \\"
	@echo "    --param pr-number=1 \\"
	@echo "    --workspace name=source,emptyDir=\"\" \\"
	@echo "    --showlog"

clean: ## Cleanup environment (delete cluster and resources)
	@cd setup && ./scripts/cleanup.sh
