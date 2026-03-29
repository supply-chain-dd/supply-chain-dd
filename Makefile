.PHONY: help setup setup-kind setup-gitea setup-tekton setup-ctf-challenge verify verify-ctf status clean
.PHONY: setup-security-tools setup-kyverno setup-kubescape security-scan apply-prevention-policies verify-security
.PHONY: check-cli-tools install-tkn install-kubescape

CLUSTER_NAME ?= ctf-cluster
GITEA_VERSION ?= 10.6.1
TEKTON_PIPELINE_VERSION ?= v0.53.0
KYVERNO_VERSION ?= v3.7.1
KUBESCAPE_VERSION ?= latest
TKN_VERSION ?= v0.35.1
KUBESCAPE_CLI_VERSION ?= v3.0.3

# ============================================================
# CLI Tools Installation
# ============================================================

check-cli-tools: ## Check if required CLI tools are installed
	@echo "Checking CLI tools..."
	@command -v kubectl >/dev/null 2>&1 || { echo "  ❌ kubectl not found. Please install kubectl first."; exit 1; }
	@echo "  ✓ kubectl installed"
	@if command -v kubectl-tkn >/dev/null 2>&1 || command -v tkn >/dev/null 2>&1; then \
		echo "  ✓ tkn CLI installed"; \
	else \
		echo "  ⚠ tkn CLI not found. Run 'make install-tkn' to install."; \
	fi
	@if command -v kubectl-kubescape >/dev/null 2>&1 || command -v kubescape >/dev/null 2>&1; then \
		echo "  ✓ kubescape CLI installed"; \
	else \
		echo "  ⚠ kubescape CLI not found. Run 'make install-kubescape' to install."; \
	fi

install-tkn: ## Install Tekton CLI as kubectl plugin
	@echo "Installing Tekton CLI (tkn) as kubectl plugin..."
	@if command -v kubectl-tkn >/dev/null 2>&1 || command -v tkn >/dev/null 2>&1; then \
		echo "  ✓ tkn CLI already installed"; \
		exit 0; \
	fi
	@echo "  Detecting OS and architecture..."
	@OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
	ARCH=$$(uname -m); \
	case $$ARCH in \
		x86_64) ARCH="amd64" ;; \
		aarch64|arm64) ARCH="arm64" ;; \
		*) echo "  ❌ Unsupported architecture: $$ARCH"; exit 1 ;; \
	esac; \
	echo "  OS: $$OS, Arch: $$ARCH"; \
	TKN_URL="https://github.com/tektoncd/cli/releases/download/$(TKN_VERSION)/tkn_$(TKN_VERSION)_$${OS}_$${ARCH}.tar.gz"; \
	echo "  Downloading from: $$TKN_URL"; \
	curl -LO "$$TKN_URL"; \
	tar xvzf tkn_$(TKN_VERSION)_$${OS}_$${ARCH}.tar.gz tkn; \
	chmod +x tkn; \
	mkdir -p ~/.local/bin; \
	mv tkn ~/.local/bin/kubectl-tkn; \
	rm -f tkn_$(TKN_VERSION)_$${OS}_$${ARCH}.tar.gz; \
	if ! echo $$PATH | grep -q "$${HOME}/.local/bin"; then \
		echo "  ⚠ Add ~/.local/bin to your PATH:"; \
		echo "    export PATH=\$$PATH:~/.local/bin"; \
	fi; \
	echo "  ✓ tkn CLI installed as kubectl-tkn"; \
	echo "  Usage: kubectl tkn <command> or tkn <command>"

install-kubescape: ## Install Kubescape CLI as kubectl plugin
	@echo "Installing Kubescape CLI as kubectl plugin..."
	@if command -v kubectl-kubescape >/dev/null 2>&1 || command -v kubescape >/dev/null 2>&1; then \
		echo "  ✓ kubescape CLI already installed"; \
		exit 0; \
	fi
	@echo "  Detecting OS and architecture..."
	@OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
	ARCH=$$(uname -m); \
	case $$ARCH in \
		x86_64) ARCH="amd64" ;; \
		aarch64|arm64) ARCH="arm64" ;; \
		*) echo "  ❌ Unsupported architecture: $$ARCH"; exit 1 ;; \
	esac; \
	echo "  OS: $$OS, Arch: $$ARCH"; \
	KUBESCAPE_URL="https://github.com/kubescape/kubescape/releases/download/$(KUBESCAPE_CLI_VERSION)/kubescape-$${OS}-$${ARCH}"; \
	echo "  Downloading from: $$KUBESCAPE_URL"; \
	curl -L "$$KUBESCAPE_URL" -o kubescape; \
	chmod +x kubescape; \
	mkdir -p ~/.local/bin; \
	mv kubescape ~/.local/bin/kubectl-kubescape; \
	if ! echo $$PATH | grep -q "$${HOME}/.local/bin"; then \
		echo "  ⚠ Add ~/.local/bin to your PATH:"; \
		echo "    export PATH=\$$PATH:~/.local/bin"; \
	fi; \
	echo "  ✓ kubescape CLI installed as kubectl-kubescape"; \
	echo "  Usage: kubectl kubescape <command> or kubescape <command>"

# ============================================================
# Help and Setup
# ============================================================

help: ## Display this help message
	@echo "Supply Chain CTF Environment - Available Commands:"
	@echo ""
	@echo "CLI Tools:"
	@grep -E '^(check-cli-tools|install-tkn|install-kubescape):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Environment Setup:"
	@grep -E '^(setup|setup-kind|setup-gitea|setup-tekton|setup-ctf-challenge):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Security Tools:"
	@grep -E '^(setup-security-tools|setup-kyverno|setup-kubescape):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Security Operations:"
	@grep -E '^(create-security-policies|apply-prevention-policies|security-scan|verify-security):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Verification:"
	@grep -E '^(verify|verify-ctf|status):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Cleanup:"
	@grep -E '^(clean):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make check-cli-tools          # Check for required CLI tools"
	@echo "  2. make setup                    # Setup complete CTF environment"
	@echo "  3. make setup-security-tools     # Deploy Kyverno + Kubescape"
	@echo "  4. make apply-prevention-policies # Apply security policies"
	@echo "  5. make security-scan            # Run security scans"
	@echo ""
	@echo "Documentation:"
	@echo "  • SECURITY-GUIDE.md - Comprehensive security tools guide"
	@echo "  • ATTACK-ANALYSIS.md - Attack comparison (GitHub vs Tekton)"
	@echo "  • security/README.md - Policy details and testing"
	@echo ""

setup: check-cli-tools setup-kind setup-gitea setup-tekton verify ## Complete setup (KinD cluster + Gitea + act_runner + verification)
	@echo ""
	@echo "✓ Setup complete! Next steps:"
	@echo "  • Run 'make setup-ctf-challenge' to install CTF resources"
	@echo "  • Run 'make setup-security-tools' to install security tools"
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
	@echo ""
	@if ! command -v kubectl-tkn >/dev/null 2>&1 && ! command -v tkn >/dev/null 2>&1; then \
		echo "💡 Tip: Install Tekton CLI for easier management:"; \
		echo "   make install-tkn"; \
		echo ""; \
	fi

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
		-n ctf-challenge --dry-run=client -o yaml | kubectl apply -f -
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
	@kubectl get pipeline pr-quality-check-pipeline -n ctf-challenge 2>/dev/null || echo "  ❌ Pipeline not found (run: make setup-ctf-challenge)"
	@echo ""
	@echo "CTF Tasks:"
	@kubectl get task quality-check-task git-clone print-info print-results -n ctf-challenge 2>/dev/null || echo "  ❌ Tasks not found"
	@echo ""
	@echo "EventListener:"
	@kubectl get eventlistener pr-quality-check-listener -n ctf-challenge 2>/dev/null || echo "  ❌ EventListener not found"
	@echo ""
	@echo "CTF Flag Secret:"
	@kubectl get secret ctf-flag -n ctf-challenge 2>/dev/null && echo "  ✓ Flag secret exists" || echo "  ❌ Flag secret not found"
	@echo ""
	@echo "ServiceAccounts:"
	@kubectl get sa tekton-triggers-sa default -n ctf-challenge 2>/dev/null || echo "  ❌ ServiceAccounts not found"
	@echo ""
	@echo "✓ Verification complete"
	@echo ""
	@echo "To test the challenge:"
	@if command -v kubectl-tkn >/dev/null 2>&1; then \
		echo "  kubectl tkn pipeline start pr-quality-check-pipeline \\"; \
	elif command -v tkn >/dev/null 2>&1; then \
		echo "  tkn pipeline start pr-quality-check-pipeline \\"; \
	else \
		echo "  (Install tkn CLI first: make install-tkn)"; \
		echo "  kubectl tkn pipeline start pr-quality-check-pipeline \\"; \
	fi
	@echo "    --param pr-repo-url=https://github.com/example/repo.git \\"
	@echo "    --param pr-sha=main \\"
	@echo "    --param pr-number=1 \\"
	@echo "    --workspace name=source,emptyDir=\"\" \\"
	@echo "    --showlog"

clean: ## Cleanup environment (delete cluster and resources)
	@cd setup && ./scripts/cleanup.sh

# ============================================================
# Security Tools Setup
# ============================================================

setup-security-tools: setup-kyverno setup-kubescape ## Deploy all security tools (Kyverno + Kubescape)
	@echo ""
	@echo "✓ All security tools deployed successfully"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Run security scans: make security-scan"
	@echo "  2. Apply prevention policies: make apply-prevention-policies"
	@echo "  3. Verify security setup: make verify-security"

setup-kyverno: ## Deploy Kyverno policy engine
	@echo "Installing Kyverno $(KYVERNO_VERSION)..."
	@kubectl create namespace kyverno 2>/dev/null || true
	@helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
	@helm repo update
	@helm upgrade --install kyverno kyverno/kyverno \
		--namespace kyverno \
		--version $(KYVERNO_VERSION) \
		--set admissionController.replicas=1 \
		--set backgroundController.replicas=1 \
		--set cleanupController.replicas=1 \
		--set reportsController.replicas=1 \
		--wait --timeout=5m
	@echo ""
	@echo "Waiting for Kyverno to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/part-of=kyverno -n kyverno --timeout=300s
	@echo "✓ Kyverno installed successfully in namespace 'kyverno'"

setup-kubescape: ## Deploy Kubescape security scanner
	@echo "Installing Kubescape..."
	@kubectl create namespace kubescape 2>/dev/null || true
	@helm repo add kubescape https://kubescape.github.io/helm-charts/ 2>/dev/null || true
	@helm repo update
	@helm upgrade --install kubescape kubescape/kubescape-operator \
		--namespace kubescape \
		--set clusterName=$(CLUSTER_NAME) \
		--set capabilities.continuousScan=enable \
		--wait --timeout=5m
	@echo ""
	@echo "Waiting for Kubescape to be ready..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kubescape -n kubescape --timeout=300s 2>/dev/null || echo "  Note: Some Kubescape components may still be initializing"
	@echo "✓ Kubescape installed successfully in namespace 'kubescape'"

# ============================================================
# Security Scanning
# ============================================================

security-scan: ## Run all security scans (static analysis + runtime checks)
	@echo "========================================"
	@echo "Running Security Scans"
	@echo "========================================"
	@echo ""
	@# Check if kubescape CLI is available
	@if ! command -v kubectl-kubescape >/dev/null 2>&1 && ! command -v kubescape >/dev/null 2>&1; then \
		echo "⚠ Kubescape CLI not found. Installing..."; \
		$(MAKE) install-kubescape; \
	fi
	@echo ""
	@echo "[1/3] Scanning Tekton resources with Kubescape..."
	@echo "------------------------------------------------"
	@if command -v kubectl-kubescape >/dev/null 2>&1; then \
		kubectl kubescape scan framework nsa,mitre tekton/ --format pretty-printer --output kubescape-report.txt || true; \
	elif command -v kubescape >/dev/null 2>&1; then \
		kubescape scan framework nsa,mitre tekton/ --format pretty-printer --output kubescape-report.txt || true; \
	else \
		echo "  ❌ Kubescape CLI not available. Run 'make install-kubescape'"; \
	fi
	@echo ""
	@echo "[2/3] Validating Tekton resources against Kyverno policies..."
	@echo "------------------------------------------------"
	@if [ -d "security/kyverno-policies" ]; then \
		kubectl kyverno apply security/kyverno-policies/ --resource tekton/ || true; \
	else \
		echo "  No Kyverno policies found in security/kyverno-policies/"; \
	fi
	@echo ""
	@echo "[3/3] Scanning cluster with Kubescape (if installed)..."
	@echo "------------------------------------------------"
	@if kubectl get ns kubescape >/dev/null 2>&1; then \
		if command -v kubectl-kubescape >/dev/null 2>&1; then \
			kubectl kubescape scan --submit=false --format pretty-printer || true; \
		elif command -v kubescape >/dev/null 2>&1; then \
			kubescape scan --submit=false --format pretty-printer || true; \
		fi; \
	else \
		echo "  Kubescape operator not installed. Run 'make setup-kubescape' first."; \
	fi
	@echo ""
	@echo "✓ Security scan complete"
	@echo ""
	@if [ -f "kubescape-report.txt" ]; then \
		echo "Reports generated:"; \
		echo "  - kubescape-report.txt"; \
	fi

# ============================================================
# Prevention Policies
# ============================================================

apply-prevention-policies: ## Apply Kyverno policies and network policies
	@echo "========================================"
	@echo "Applying Prevention Policies"
	@echo "========================================"
	@echo ""
	@echo "[1/3] Applying Kyverno policies..."
	@echo "------------------------------------------------"
	@if [ -d "security/kyverno-policies" ]; then \
		kubectl apply -f security/kyverno-policies/; \
		echo "✓ Kyverno policies applied"; \
	else \
		echo "  ❌ No Kyverno policies found in security/kyverno-policies/"; \
		echo "  Run: make create-security-policies"; \
	fi
	@echo ""
	@echo "[2/3] Applying Network Policies..."
	@echo "------------------------------------------------"
	@if [ -d "security/network-policies" ]; then \
		kubectl apply -f security/network-policies/; \
		echo "✓ Network policies applied"; \
	else \
		echo "  ❌ No Network policies found in security/network-policies/"; \
		echo "  Run: make create-security-policies"; \
	fi
	@echo ""
	@echo "[3/3] Applying RBAC hardening..."
	@echo "------------------------------------------------"
	@if [ -f "security/rbac/minimal-serviceaccounts.yaml" ]; then \
		kubectl apply -f security/rbac/; \
		echo "✓ RBAC policies applied"; \
	else \
		echo "  ❌ No RBAC policies found in security/rbac/"; \
		echo "  Run: make create-security-policies"; \
	fi
	@echo ""
	@echo "✓ All prevention policies applied"

create-security-policies: ## Create security policy files (Kyverno, NetworkPolicy, RBAC)
	@cd setup && ./scripts/create-security-policies.sh

# ============================================================
# Security Verification
# ============================================================

verify-security: ## Verify security tools and policies are working
	@echo "========================================"
	@echo "Verifying Security Setup"
	@echo "========================================"
	@echo ""
	@echo "Kyverno Status:"
	@echo "------------------------------------------------"
	@kubectl get pods -n kyverno 2>/dev/null || echo "  ❌ Kyverno not installed (run: make setup-kyverno)"
	@kubectl get clusterpolicy,policy --all-namespaces 2>/dev/null || echo "  No policies found"
	@echo ""
	@echo "Kubescape Status:"
	@echo "------------------------------------------------"
	@kubectl get pods -n kubescape 2>/dev/null || echo "  ❌ Kubescape not installed (run: make setup-kubescape)"
	@echo ""
	@echo "Network Policies:"
	@echo "------------------------------------------------"
	@kubectl get networkpolicy --all-namespaces 2>/dev/null || echo "  No NetworkPolicies found"
	@echo ""
	@echo "ServiceAccounts (CTF Challenge):"
	@echo "------------------------------------------------"
	@kubectl get sa -n ctf-challenge 2>/dev/null || echo "  CTF challenge not set up"
	@echo ""
	@echo "✓ Security verification complete"