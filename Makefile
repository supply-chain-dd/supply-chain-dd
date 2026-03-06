.PHONY: help setup setup-kind setup-gitea setup-act-runner verify status clean

CLUSTER_NAME ?= ctf-cluster
GITEA_VERSION ?= 10.6.1

help: ## Display this help message
	@echo "Supply Chain CTF Environment - Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: setup-kind setup-gitea setup-act-runner verify ## Complete setup (KinD cluster + Gitea + act_runner + verification)

setup-kind: ## Create KinD cluster
	@cd setup && ./scripts/setup-kind.sh

setup-gitea: ## Install Gitea via Helm
	@cd setup && ./scripts/setup-gitea.sh

setup-act-runner: ## Install Gitea Actions Runner
	@cd setup && ./scripts/setup-act-runner.sh

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
	@echo ""
	@echo "Act Runner:"
	@kubectl get pods -n gitea -l app=act-runner 2>/dev/null || echo "  Act runner not installed"
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
	@echo "Act Runner:"
	@kubectl get pods -n gitea -l app=act-runner 2>/dev/null || echo "  Act runner not installed"
	@echo ""
	@echo "Access Gitea at: http://localhost:30002"

clean: ## Cleanup environment (delete cluster and resources)
	@cd setup && ./scripts/cleanup.sh
