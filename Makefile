.PHONY: help setup clean setup-kind setup-tekton verify

CLUSTER_NAME ?= ctf-cluster
TEKTON_PIPELINE_VERSION ?= v0.53.0

help: ## Display this help message
	@echo "CTF Environment Setup"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

setup: setup-kind setup-tekton verify ## Complete CTF environment setup
	@echo ""
	@echo "✓ CTF environment setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  - Run 'kubectl get pods -A' to verify all components"
	@echo "  - Run 'make verify' to check the environment"

setup-kind: ## Create KinD cluster
	@./scripts/setup-kind.sh

setup-tekton: ## Install Tekton pipelines
	@./scripts/setup-tekton.sh

verify: ## Verify the CTF environment is working
	@echo "Verifying CTF environment..."
	@echo -n "Checking cluster access... "
	@kubectl cluster-info > /dev/null 2>&1 && echo "✓" || (echo "✗" && exit 1)
	@echo -n "Checking Tekton installation... "
	@kubectl get pods -n tekton-pipelines > /dev/null 2>&1 && echo "✓" || (echo "✗" && exit 1)
	@echo ""
	@echo "Environment verification complete!"

clean: ## Delete the KinD cluster and cleanup
	@echo "Cleaning up CTF environment..."
	@kind delete cluster --name $(CLUSTER_NAME) || true
	@echo "✓ Cleanup complete"

status: ## Show status of the environment
	@echo "CTF Environment Status"
	@echo "======================"
	@echo ""
	@echo "KinD Clusters:"
	@kind get clusters || echo "  No clusters found"
	@echo ""
	@echo "Kubernetes Context:"
	@kubectl config current-context || echo "  No context set"
	@echo ""
	@echo "Tekton Pipelines (if cluster exists):"
	@kubectl get pods -n tekton-pipelines 2>/dev/null || echo "  Not installed or cluster not running"
