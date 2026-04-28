.PHONY: help setup setup-kind setup-gitea setup-tekton setup-tektonchains setup-registry seed-victim-repo setup-ctf-challenge setup-ctf-challenge-secure verify verify-ctf status clean
.PHONY: setup-security-tools setup-kyverno setup-kubescape security-scan apply-prevention-policies verify-security create-security-policies
.PHONY: check-cli-tools install-tkn install-kubescape verify-registry configure-registry-tls verify-tektonchains
.PHONY: setup-challenge1 setup-challenge2 build-recipe-api push-recipe-api verify-challenge2 setup-challenge2-tekton trigger-challenge2-build
.PHONY: setup-challenge3 seed-legitimate-base-image verify-challenge3
.PHONY: setup-production-cluster setup-production-gitea seed-production-repo load-image-to-production setup-argocd setup-challenge4 verify-challenge4 clean-challenge4 apply-challenge4-security test-challenge4-attack
.PHONY: setup-demo setup-gitea-webhooks verify-demo-readiness

CLUSTER_NAME ?= ctf-cluster
GITEA_HELM_VERSION ?= v12.5.0
TEKTON_PIPELINE_VERSION ?= v0.53.0
TEKTON_CHAINS_VERSION ?= v0.26.3
KYVERNO_VERSION ?= v3.7.1
KUBESCAPE_VERSION ?= latest
TKN_VERSION ?= v0.44.1
KUBESCAPE_CLI_VERSION ?= v3.0.3
REGISTRY_PORT ?= 5000
REGISTRY_NODE_PORT ?= 30000
REGISTRY_USER ?= ctf-admin
REGISTRY_PASS ?= CTFRegistryPass123!

# Container runtime selection (podman or docker)
CONTAINER_RUNTIME ?= podman

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
		x86_64) ARCH="x86_64" ;; \
		arm64) ARCH="arm64" ;; \
		*) echo "  ❌ Unsupported architecture: $$ARCH"; exit 1 ;; \
	esac; \
	echo "  OS: $$OS, Arch: $$ARCH"; \
	TKN_VERSION_RAW=$$(echo $(TKN_VERSION) | cut -f2 -dv); \
	TKN_URL="https://github.com/tektoncd/cli/releases/download/$(TKN_VERSION)/tkn_$${TKN_VERSION_RAW}_$${OS}_$${ARCH}.tar.gz"; \
	echo "  Downloading from: $$TKN_URL"; \
	curl -LO "$$TKN_URL"; \
	tar xvzf tkn_$${TKN_VERSION_RAW}_$${OS}_$${ARCH}.tar.gz tkn; \
	chmod +x tkn; \
	mkdir -p ~/.local/bin; \
	mv tkn ~/.local/bin/kubectl-tkn; \
	rm -f tkn_$${TKN_VERSION_RAW}_$${OS}_$${ARCH}.tar.gz; \
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
	@echo "🚀 Quick Start (Deep Dive Demo):"
	@echo "  \033[36mmake setup-demo\033[0m              Complete automated setup for Challenges 1 & 2"
	@echo "  \033[36mmake verify-demo-readiness\033[0m   Verify all prerequisites are met"
	@echo "  See DEMO-SETUP.md for detailed instructions"
	@echo ""
	@echo "CLI Tools:"
	@grep -E '^(check-cli-tools|install-tkn|install-kubescape):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Environment Setup:"
	@grep -E '^(setup|setup-kind|setup-gitea|setup-tekton|setup-tektonchains|setup-registry|configure-registry-tls|seed-victim-repo|setup-ctf-challenge|setup-ctf-challenge-secure|setup-gitea-webhooks):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Security Tools:"
	@grep -E '^(setup-security-tools|setup-kyverno|setup-kubescape):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Security Operations:"
	@grep -E '^(create-security-policies|apply-prevention-policies|security-scan|verify-security):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Verification:"
	@grep -E '^(verify|verify-ctf|verify-registry|verify-tektonchains|verify-demo-readiness|status):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Cleanup:"
	@grep -E '^(clean):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick Start (Manual Steps):"
	@echo "  1. make check-cli-tools          # Check for required CLI tools"
	@echo "  2. make setup                    # Setup complete CTF environment"
	@echo "  3. make configure-registry-tls   # Configure registry TLS trust"
	@echo "  4. make setup-ctf-challenge      # Setup Challenge 1"
	@echo "  5. make setup-challenge2-tekton  # Setup Challenge 2"
	@echo "  6. make setup-gitea-webhooks     # Create Gitea webhooks"
	@echo "  7. make verify-demo-readiness    # Verify everything is ready"
	@echo ""
	@echo "Environment Variables:"
	@echo "  CONTAINER_RUNTIME=podman|docker  # Select container runtime (default: podman)"
	@echo "  Example: CONTAINER_RUNTIME=docker make build-recipe-api"
	@echo ""
	@echo "  Note: Registry uses TLS with self-signed certificates."
	@echo "        Run 'make configure-registry-tls' to trust the certificate."
	@echo ""
	@echo "Documentation:"
	@echo "  • DEMO-SETUP.md - Deep dive demo automation guide"
	@echo "  • SECURITY-GUIDE.md - Comprehensive security tools guide"
	@echo "  • challenges/challenge1/ATTACK-ANALYSIS.md - Attack comparison"
	@echo "  • challenges/challenge1/security/README.md - Policy details"
	@echo "  • challenges/challenge2/ATTACK-ANALYSIS.md - Container layer attack"
	@echo ""

setup: check-cli-tools setup-kind setup-gitea setup-tekton setup-registry verify ## Complete setup (KinD cluster + Gitea + tekton + registry + verification)
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

setup-tektonchains: ## Install and configure Tekton Chains for supply chain security
	@cd setup && ./scripts/setup-tektonchains.sh
	@echo ""
	@echo "💡 Tekton Chains is now configured with:"
	@echo "   • Format: in-toto (AMPEL/Conforma compatible)"
	@echo "   • Storage: OCI registry"
	@echo "   • Deep inspection: enabled"
	@echo ""
	@echo "Next steps:"
	@echo "   • Run pipelines to automatically generate attestations"
	@echo "   • Configure OCI registry credentials if needed"
	@echo "   • Verify installation: make verify-tektonchains"
	@echo ""

setup-registry: ## Setup local Docker registry with authentication
	@cd setup && ./scripts/setup-registry.sh

configure-registry-tls: ## Configure TLS trust for the registry (interactive)
	@cd setup && ./scripts/configure-registry-tls.sh

seed-victim-repo: ## Seed recipe-api repository to CTF cluster Gitea
	@./setup/scripts/seed-victim-repo.sh

setup-ctf-challenge: seed-victim-repo ## Install Tekton CTF challenge resources (VULNERABLE version)
	@echo "Installing Tekton CTF Challenge (VULNERABLE version)..."
	@kubectl create namespace ctf-challenge 2>/dev/null || true
	@echo ""	
	@echo "Setting up registry CA certificate for Tekton..."
	@cd setup/scripts && ./setup-registry-cert-for-tekton.sh
	@echo ""
	@kubectl apply -f challenges/challenge1/tekton/triggers/vulnerable-eventlistener.yaml
	@kubectl apply -f challenges/challenge1/tekton/tasks/supporting-tasks.yaml
	@kubectl apply -f challenges/challenge1/tekton/tasks/vulnerable-quality-check-task.yaml
	@kubectl apply -f challenges/challenge1/tekton/pipelines/vulnerable-pr-quality-pipeline.yaml
	@echo ""
	@echo "Creating CTF flag secret with registry credentials..."
	@kubectl create secret generic ctf-flag \
		--from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
		--from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
		--from-literal=registry-user='$(REGISTRY_USER)' \
		--from-literal=registry-password='$(REGISTRY_PASS)' \
		-n ctf-challenge --dry-run=client -o yaml | kubectl apply -f -
	
	@echo "Next steps:"
	@echo "  1. Complete victim repository setup: challenges/challenge1/SETUP.md"
	@echo "  2. Review the challenge guide: challenges/challenge1/CTF-CHALLENGE-GUIDE.md"
	@echo "  3. Test the attack: make verify-ctf"
	@echo ""
	@echo "To deploy SECURE version instead:"
	@echo "  make setup-ctf-challenge-secure"

setup-ctf-challenge-secure: ## Install Tekton CTF challenge with SECURE configuration
	@echo "Installing Tekton CTF Challenge (SECURE version)..."
	@kubectl create namespace ctf-challenge 2>/dev/null || true
	@echo ""
	@echo "Step 1: Deploying security RBAC (minimal ServiceAccounts)..."
	@kubectl apply -f challenges/challenge1/security/rbac/minimal-serviceaccounts.yaml
	@echo ""
	@echo "Step 2: Deploying secure Tekton resources..."
	@kubectl apply -f challenges/challenge1/tekton-patched/tasks/
	@kubectl apply -f challenges/challenge1/tekton-patched/pipelines/
	@kubectl apply -f challenges/challenge1/tekton-patched/triggers/
	@echo ""
	@echo "Step 3: Creating CTF flag secret with registry credentials..."
	@kubectl create secret generic ctf-flag \
		--from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
		--from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
		--from-literal=registry-user='$(REGISTRY_USER)' \
		--from-literal=registry-password='$(REGISTRY_PASS)' \
		-n ctf-challenge --dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "✓ CTF Challenge installed successfully (SECURE version)"
	@echo ""
	@echo "✅ Security controls enabled:"
	@echo "   - Uses pr-pipeline-readonly ServiceAccount (NO secret access)"
	@echo "   - Minimal RBAC permissions"
	@echo "   - Default SA has zero permissions"
	@echo "   - Attack will be BLOCKED by RBAC"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Apply Network Policies: make apply-prevention-policies"
	@echo "  2. Verify security: make verify-security"
	@echo "  3. Test that attack is blocked: see challenges/challenge1/tekton-patched/README.md"
	@echo ""
	@echo "To compare with vulnerable version:"
	@echo "  diff -u challenges/challenge1/tekton/ challenges/challenge1/tekton-patched/"

verify: verify-registry
 ## Verify environment is working correctly
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
	@echo "Registry:"
	@kubectl get pods -n registry 2>/dev/null || echo "  Registry not running (run: make setup-registry)"
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
	@echo "Registry:"
	@kubectl get pods,svc -n registry 2>/dev/null || echo "  Registry not running (run: make setup-registry)"
	@echo ""
	@echo "Access URLs:"
	@echo "  Gitea:    http://localhost:30002"
	@echo "  Registry: https://localhost:$(REGISTRY_NODE_PORT)"

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

verify-registry: ## Verify registry is working correctly
	@echo "Verifying Docker Registry..."
	@echo ""
	@echo "Registry Deployment:"
	@kubectl get deployment registry -n registry 2>/dev/null || { echo "  ❌ Registry deployment not found (run: make setup-registry)"; exit 1; }
	@echo ""
	@echo "Registry Pods:"
	@kubectl get pods -n registry -l app=registry 2>/dev/null || echo "  ❌ Registry pods not found"
	@echo ""
	@echo "Registry Service:"
	@kubectl get svc registry -n registry 2>/dev/null || echo "  ❌ Registry service not found"
	@echo ""
	@echo "Registry PVC:"
	@kubectl get pvc registry-storage -n registry 2>/dev/null || echo "  ❌ Registry storage not found"
	@echo ""
	@echo "Registry Secret:"
	@kubectl get secret registry-auth -n registry 2>/dev/null && echo "  ✓ Registry auth secret exists" || echo "  ❌ Registry auth secret not found"
	@echo ""
	@echo "Testing registry connectivity..."
	@echo "  External (from host):"
	@curl -k -sf -u $(REGISTRY_USER):$(REGISTRY_PASS) https://localhost:$(REGISTRY_NODE_PORT)/v2/_catalog 2>/dev/null && \
		echo "    ✓ Registry accessible from host" || \
		echo "    ❌ Registry not accessible from host"
	@echo ""
	@echo "  Internal (from cluster):"
	@kubectl run test-registry-verify --image=curlimages/curl:latest --rm -i --restart=Never --timeout=30s -- \
		sh -c 'curl -k -sf -u $(REGISTRY_USER):$(REGISTRY_PASS) https://registry.registry.svc.cluster.local:5000/v2/_catalog' 2>/dev/null && \
		echo "    ✓ Registry accessible from cluster" || \
		echo "    ❌ Registry not accessible from cluster"
	@echo ""
	@echo "✓ Registry verification complete"
	@echo ""
	@echo "Registry credentials:"
	@echo "  Username: $(REGISTRY_USER)"
	@echo "  Password: $(REGISTRY_PASS)"

verify-tektonchains: ## Verify Tekton Chains installation and configuration
	@echo "Verifying Tekton Chains..."
	@echo ""
	@echo "Tekton Chains Namespace:"
	@kubectl get namespace tekton-chains 2>/dev/null && echo "  ✓ Namespace exists" || { echo "  ❌ Namespace not found (run: make setup-tektonchains)"; exit 1; }
	@echo ""
	@echo "Tekton Chains Controller:"
	@kubectl get deployment tekton-chains-controller -n tekton-chains 2>/dev/null && echo "  ✓ Controller deployment exists" || echo "  ❌ Controller not found"
	@echo ""
	@kubectl get pods -n tekton-chains -l app.kubernetes.io/name=controller 2>/dev/null || echo "  ❌ Controller pods not found"
	@echo ""
	@echo "Tekton Chains Configuration:"
	@kubectl get configmap chains-config -n tekton-chains 2>/dev/null && echo "  ✓ Config exists" || echo "  ❌ Config not found"
	@echo ""
	@echo "Current Configuration Settings:"
	@kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data.artifacts\.pipelinerun\.format}' 2>/dev/null && echo "" || echo "  ❌ Format not configured"
	@echo "  Format: $$(kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data.artifacts\.pipelinerun\.format}' 2>/dev/null || echo 'not set')"
	@echo "  Storage: $$(kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data.artifacts\.pipelinerun\.storage}' 2>/dev/null || echo 'not set')"
	@echo "  Deep Inspection: $$(kubectl get configmap chains-config -n tekton-chains -o jsonpath='{.data.artifacts\.pipelinerun\.enable-deep-inspection}' 2>/dev/null || echo 'not set')"
	@echo ""
	@echo "✓ Tekton Chains verification complete"
	@echo ""
	@echo "Pipelines configured for attestation:"
	@echo "  • pr-quality-check-pipeline (Challenge 1)"
	@echo "  • push-build-pipeline (Challenge 2)"

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
		kubectl kubescape scan framework nsa,mitre challenges/challenge1/tekton/ --format pretty-printer --output kubescape-report.txt || true; \
	elif command -v kubescape >/dev/null 2>&1; then \
		kubescape scan framework nsa,mitre challenges/challenge1/tekton/ --format pretty-printer --output kubescape-report.txt || true; \
	else \
		echo "  ❌ Kubescape CLI not available. Run 'make install-kubescape'"; \
	fi
	@echo ""
	@echo "[2/3] Validating Tekton resources against Kyverno policies..."
	@echo "------------------------------------------------"
	@if [ -d "security/kyverno-policies" ]; then \
		kubectl kyverno apply security/kyverno-policies/ --resource challenges/challenge1/tekton/ || true; \
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
	@if [ -d "challenges/challenge1/security/kyverno-policies" ]; then \
		kubectl apply -f challenges/challenge1/security/kyverno-policies/; \
		echo "✓ Kyverno policies applied"; \
	else \
		echo "  ❌ No Kyverno policies found in security/kyverno-policies/"; \
		echo "  Run: make challenges/challenge1/create-security-policies"; \
	fi
	@echo ""
	@echo "[2/3] Applying Network Policies..."
	@echo "------------------------------------------------"
	@if [ -d "challenges/challenge1/security/network-policies" ]; then \
		kubectl apply -f challenges/challenge1/security/network-policies/; \
		echo "✓ Network policies applied"; \
	else \
		echo "  ❌ No Network policies found in security/network-policies/"; \
		echo "  Run: make create-security-policies"; \
	fi
	@echo ""
	@echo "[3/3] Applying RBAC hardening..."
	@echo "------------------------------------------------"
	@if [ -f "challenges/challenge1/security/rbac/minimal-serviceaccounts.yaml" ]; then \
		kubectl apply -f challenges/challenge1/security/rbac/; \
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
# ============================================================
# Challenge 2: Container Image Layer Leak
# ============================================================

setup-challenge2: setup-registry seed-legitimate-base-image build-recipe-api push-recipe-api ## Setup Challenge 2 (container layer leak)
	@echo ""
	@echo "========================================"
	@echo "Challenge 2: Container Image Layer Leak"
	@echo "========================================"
	@echo ""
	@echo "✓ Registry deployed and configured"
	@echo "✓ Legitimate base image seeded (golang:1.25-alpine)"
	@echo "✓ recipe-api:v1.0 image built and pushed"
	@echo ""
	@echo "Attack #1 flag updated with registry credentials"
	@echo "  FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us:NEXT:registry_layer_leak}"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Complete Attack #1 to obtain registry credentials"
	@echo "  2. Review guide: challenges/challenge2/ATTACK2-README.md"
	@echo "  3. Verify setup: make verify-challenge2"
	@echo ""

build-recipe-api: ## Build the recipe-api container image
	@echo "Building recipe-api:v1.0 image..."
	@echo "  Preparing build context (restoring git history)..."
	@rm -rf /tmp/recipe-api-build
	@cp -r challenges/victim-repo-sample /tmp/recipe-api-build
	@if [ -d /tmp/recipe-api-build/_git ]; then \
		mv /tmp/recipe-api-build/_git /tmp/recipe-api-build/.git; \
		echo "  ✓ Git history restored from _git"; \
	fi
	@echo "  Building image with leaked git history..."
	@cd /tmp/recipe-api-build && \
		$(CONTAINER_RUNTIME) build -t localhost:$(REGISTRY_NODE_PORT)/recipe-api:v1.0 -f Dockerfile . 2>&1 | grep -E "(STEP|Successfully|Error)" || true
	@echo "✓ Image built successfully with .git in layers"
	@echo "  Note: /tmp/recipe-api-build contains the build context (you can inspect it)"

push-recipe-api: ## Push recipe-api image to registry
	@echo "Pushing recipe-api:v1.0 to registry..."
	@$(CONTAINER_RUNTIME) login localhost:$(REGISTRY_NODE_PORT) \
		-u $(REGISTRY_USER) -p $(REGISTRY_PASS) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) push localhost:$(REGISTRY_NODE_PORT)/recipe-api:v1.0
	@echo "✓ Image pushed to registry"

verify-challenge2: ## Verify Challenge 2 setup
	@echo "Verifying Challenge 2 setup..."
	@cd challenges/challenge2 && ./test-attack2.sh

setup-challenge2-tekton: ## Setup Challenge 2 Tekton pipeline resources
	@echo "========================================"
	@echo "Installing Challenge 2 Tekton Resources"
	@echo "========================================"
	@kubectl create namespace ctf-challenge 2>/dev/null || true
	@echo ""
	@echo "Setting up Git credentials for Gitea..."
	@kubectl apply -f challenges/challenge2/tekton/gitea-credentials.yaml
	@echo ""
	@echo "Setting up ServiceAccounts and RBAC..."
	@kubectl apply -f challenges/challenge2/tekton/serviceaccounts.yaml
	@echo ""
	@echo "Setting up registry CA certificate for Tekton..."
	@cd setup/scripts && ./setup-registry-cert-for-tekton.sh
	@echo ""
	@echo "Creating registry Docker config secret..."
	@kubectl apply -f challenges/challenge2/tekton/registry-docker-config-secret.yaml
	@echo ""
	@echo "Applying Challenge 2 Tekton tasks..."
	@kubectl apply -f challenges/challenge2/tekton/tasks/
	@echo ""
	@echo "Applying Challenge 2 Tekton pipeline..."
	@kubectl apply -f challenges/challenge2/tekton/pipelines/
	@echo ""
	@echo "Applying Challenge 2 Tekton EventListener..."
	@kubectl apply -f challenges/challenge2/tekton/triggers/
	@echo ""
	@echo "Creating CTF flag secret with registry credentials (if not exists)..."
	@kubectl create secret generic ctf-flag \
		--from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
		--from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
		--from-literal=registry-user='$(REGISTRY_USER)' \
		--from-literal=registry-password='$(REGISTRY_PASS)' \
		-n ctf-challenge --dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "✓ Challenge 2 Tekton resources installed successfully"
	@echo ""
	@echo "Pipeline: push-build-pipeline"
	@echo "  - Triggers on push events"
	@echo "  - Builds Go application"
	@echo "  - Runs quality checks"
	@echo "  - Builds container image"
	@echo "  - Pushes to registry"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Trigger a build: make trigger-challenge2-build"
	@echo "  2. Monitor pipeline runs: kubectl get pipelineruns -n ctf-challenge"
	@if command -v kubectl-tkn >/dev/null 2>&1; then \
		echo "  3. View logs: kubectl tkn pipelinerun logs -f -n ctf-challenge"; \
	elif command -v tkn >/dev/null 2>&1; then \
		echo "  3. View logs: tkn pipelinerun logs -f -n ctf-challenge"; \
	else \
		echo "  3. Install tkn for easier log viewing: make install-tkn"; \
	fi

trigger-challenge2-build: ## Trigger Challenge 2 pipeline to build and push image
	@echo "========================================"
	@echo "Triggering Challenge 2 Build Pipeline"
	@echo "========================================"
	@echo ""
	@if ! kubectl get pipeline push-build-pipeline -n ctf-challenge >/dev/null 2>&1; then \
		echo "❌ Pipeline not found. Run 'make setup-challenge2-tekton' first"; \
		exit 1; \
	fi
	@echo "Preparing recipe-api repository for build..."
	@rm -rf /tmp/gitea/recipe-api-build
	@mkdir -p /tmp/gitea
	@cp -r challenges/victim-repo-sample /tmp/gitea/recipe-api-build
	@if [ -d /tmp/gitea/recipe-api-build/_git ]; then \
		mv /tmp/gitea/recipe-api-build/_git /tmp/gitea/recipe-api-build/.git; \
		echo "  ✓ Git history restored"; \
	fi
	@echo ""
	@echo "Starting pipeline run..."
	@kubectl create -f challenges/challenge2/tekton/manual-pipelinerun.yaml
	@echo ""
	@echo "  ✓ PipelineRun created"
	@echo ""
	@echo "  Monitor with:"
	@echo "    kubectl get pipelineruns -n ctf-challenge -w"
	@echo ""
	@if command -v kubectl-tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    kubectl tkn pipelinerun logs -f -n ctf-challenge"; \
	elif command -v tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    tkn pipelinerun logs -f -n ctf-challenge"; \
	else \
		echo "  Install tkn for easier log viewing:"; \
		echo "    make install-tkn"; \
	fi
	@echo ""
	@echo "✓ Pipeline triggered successfully"
	@echo ""
	@echo "Image will be pushed to: registry.registry.svc.cluster.local:5000/recipe-api:latest"

# ============================================================
# Deep Dive Demo Setup (Challenges 1 & 2)
# ============================================================

setup-demo: setup configure-registry-tls seed-legitimate-base-image setup-ctf-challenge setup-challenge2-tekton setup-gitea-webhooks verify-demo-readiness trigger-challenge2-build ## Complete automated setup for deep dive demo (Challenges 1 & 2)
	@echo ""
	@echo "=========================================="
	@echo "✓ Deep Dive Demo Environment Ready!"
	@echo "=========================================="
	@echo ""
	@echo "Access Information:"
	@echo "  Gitea:    http://localhost:$(GITEA_HTTP_PORT)"
	@echo "  Registry: https://localhost:$(REGISTRY_NODE_PORT)"
	@echo "  Username: ctf-admin"
	@echo "  Password: CTFSecurePass123!"
	@echo ""
	@echo "Challenges Ready:"
	@echo "  • Challenge 1: PR Quality Check Attack"
	@echo "  • Challenge 2: Container Layer Leak Attack"
	@echo ""
	@echo "Start the Demo:"
	@echo "  1. Open Gitea: http://localhost:$(GITEA_HTTP_PORT)"
	@echo "  2. Create a pull request in recipe-api repository"
	@echo "  3. Follow attack guide: challenges/challenge1/CTF-CHALLENGE-GUIDE.md"
	@echo "  4. Monitor pipelines: kubectl get pipelineruns -n ctf-challenge -w"
	@echo ""

setup-gitea-webhooks: ## Setup Gitea webhooks for Tekton EventListeners
	@./setup/scripts/setup-gitea-webhooks.sh

verify-demo-readiness: ## Verify all prerequisites for deep dive demo are met
	@./setup/scripts/verify-demo-readiness.sh

# ============================================================
# Challenge 3: Malware in Base Image
# ============================================================

setup-challenge3: setup-registry ## Setup Challenge 3 (base image poisoning)
	@echo ""
	@echo "============================================"
	@echo "Challenge 3: Malware in Base Image Attack"
	@echo "============================================"
	@echo ""
	@echo "✓ Registry deployed and configured"
	@echo ""
	@echo "Prerequisites:"
	@echo "  • Challenge 1 completed (registry credentials obtained)"
	@echo "  • Challenge 2 completed (legitimate base image seeded)"
	@echo "  • Victim repository Dockerfile uses localhost:$(REGISTRY_NODE_PORT)/golang:1.25-alpine"
	@echo ""
	@echo "Attack Scenario:"
	@echo "  1. Create malicious base image with backdoor"
	@echo "  2. Push poisoned image to registry (overwrites legitimate base)"
	@echo "  3. Trigger build pipeline"
	@echo "  4. Malware embedded in recipe-api production image"
	@echo ""
	@echo "Next Steps:"
	@echo "  1. Follow setup: challenges/challenge3/SETUP.md"
	@echo "  2. Execute attack: challenges/challenge3/CTF-CHALLENGE-GUIDE.md"
	@echo "  3. Learn detection: challenges/challenge3/SECURITY-GUIDE.md"
	@echo ""
	@echo "Flag: FLAG{b4s3_1m4g3_p01s0n1ng_supply_ch41n:NEXT:gitops_compromise}"

seed-legitimate-base-image: ## Seed legitimate golang base image to local registry
	@echo "Seeding legitimate base image to registry..."
	@if ! $(CONTAINER_RUNTIME) images | grep -q "golang.*1.25-alpine"; then \
		echo "  Pulling golang:1.25-alpine..."; \
		$(CONTAINER_RUNTIME) pull golang:1.25-alpine; \
	else \
		echo "  ✓ golang:1.25-alpine already pulled"; \
	fi
	@echo "  Tagging as localhost:$(REGISTRY_NODE_PORT)/golang:1.25-alpine..."
	@$(CONTAINER_RUNTIME) tag golang:1.25-alpine localhost:$(REGISTRY_NODE_PORT)/golang:1.25-alpine
	@echo "  Logging in to registry..."
	@$(CONTAINER_RUNTIME) login localhost:$(REGISTRY_NODE_PORT) \
		-u $(REGISTRY_USER) -p $(REGISTRY_PASS) 2>/dev/null || true
	@echo "  Pushing to registry..."
	@$(CONTAINER_RUNTIME) push localhost:$(REGISTRY_NODE_PORT)/golang:1.25-alpine
	@echo "✓ Legitimate base image seeded to registry"

verify-challenge3: ## Verify Challenge 3 setup
	@echo "Verifying Challenge 3 setup..."
	@echo ""
	@echo "Registry Status:"
	@kubectl get pods,svc -n registry 2>/dev/null || { echo "  ❌ Registry not running (run: make setup-registry)"; exit 1; }
	@echo ""
	@echo "Base Image in Registry:"
	@if curl --cacert certs/registry.crt -s -u $(REGISTRY_USER):$(REGISTRY_PASS) \
		https://localhost:$(REGISTRY_NODE_PORT)/v2/golang/tags/list 2>/dev/null | grep -q "1.25-alpine"; then \
		echo "  ✓ golang:1.25-alpine exists in registry"; \
	else \
		echo "  ❌ Base image not found (run: make seed-legitimate-base-image)"; \
		exit 1; \
	fi
	@echo ""
	@echo "Victim Dockerfile Configuration:"
	@if grep -q "FROM localhost:$(REGISTRY_NODE_PORT)/golang:1.25-alpine" challenges/victim-repo-sample/Dockerfile; then \
		echo "  ✓ Dockerfile uses local registry base image"; \
	else \
		echo "  ❌ Dockerfile not configured for challenge3"; \
		exit 1; \
	fi
	@echo ""
	@echo "Registry Credentials (from Challenge 1):"
	@echo "  URL:      https://localhost:$(REGISTRY_NODE_PORT)"
	@echo "  Username: $(REGISTRY_USER)"
	@echo "  Password: $(REGISTRY_PASS)"
	@echo ""
	@echo "✓ Challenge 3 environment ready"
	@echo ""
	@echo "Next: Follow challenges/challenge3/CTF-CHALLENGE-GUIDE.md to execute the attack"


# ============================================================
# Challenge 4: GitOps Pipeline Compromise
# ============================================================

PRODUCTION_CLUSTER_NAME ?= ctf-production-cluster
PRODUCTION_GITEA_HTTP_PORT ?= 30004
PRODUCTION_GITEA_SSH_PORT ?= 30005
ARGOCD_VERSION ?= 5.51.0
ARGOCD_NAMESPACE ?= argocd

setup-production-cluster: ## Create production KinD cluster for Challenge 4
	@./setup/scripts/setup-production-cluster.sh

setup-production-gitea: ## Install Gitea on production cluster
	@./setup/scripts/setup-production-gitea.sh

seed-production-repo: ## Seed production-manifests repository to production Gitea
	@./setup/scripts/seed-production-repo.sh

load-image-to-production: ## Load recipe-api image into production cluster
	@./setup/scripts/load-image-to-production.sh

setup-argocd: ## Install ArgoCD on production cluster
	@./setup/scripts/setup-argocd.sh

setup-challenge4: setup-production-cluster setup-production-gitea load-image-to-production setup-argocd seed-production-repo ## Complete Challenge 4 setup
	@echo ""
	@echo "Applying ArgoCD application..."
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) apply -f challenges/challenge4/argocd/recipe-api-application.yaml
	@echo ""
	@echo "Waiting for ArgoCD to sync application..."
	@sleep 5
	@echo ""
	@echo "========================================"
	@echo "Challenge 4 Setup Complete"
	@echo "========================================"
	@echo ""
	@echo "✓ Production KinD cluster created: $(PRODUCTION_CLUSTER_NAME)"
	@echo "✓ Production Gitea installed (http://localhost:30004)"
	@echo "✓ recipe-api image loaded into production cluster"
	@echo "✓ ArgoCD installed in namespace: $(ARGOCD_NAMESPACE)"
	@echo "✓ production-manifests repository seeded"
	@echo "✓ ArgoCD application deployed (recipe-api-production)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Verify setup: make verify-challenge4"
	@echo "  2. Check ArgoCD sync status: kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) get applications -n argocd"
	@echo "  3. Start the attack: challenges/challenge4/CTF-CHALLENGE-GUIDE.md"
	@echo ""

verify-challenge4: ## Verify Challenge 4 setup
	@echo "Verifying Challenge 4 setup..."
	@echo ""
	@echo "Production Cluster:"
	@kind get clusters | grep -q "$(PRODUCTION_CLUSTER_NAME)" && echo "  ✓ Production cluster exists" || echo "  ❌ Production cluster not found"
	@echo ""
	@echo "Production Gitea:"
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) get pods -n gitea 2>/dev/null | grep -q Running && echo "  ✓ Gitea running on production cluster" || echo "  ❌ Gitea not installed"
	@echo ""
	@echo "ArgoCD Pods:"
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) get pods -n $(ARGOCD_NAMESPACE) 2>/dev/null | grep -q Running && echo "  ✓ ArgoCD running" || echo "  ❌ ArgoCD not installed"
	@echo ""
	@echo "ArgoCD Applications:"
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) get applications -n $(ARGOCD_NAMESPACE) 2>/dev/null || echo "  ⚠ No applications deployed yet"
	@echo ""
	@echo "Production Namespace:"
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) get namespace production 2>/dev/null && echo "  ✓ Production namespace exists" || echo "  ⚠ Production namespace not created"
	@echo ""
	@echo "Recipe API Deployment:"
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) get deployment -n production 2>/dev/null || echo "  ⚠ No deployments in production namespace yet"
	@echo ""

clean-challenge4: ## Cleanup Challenge 4 (delete production cluster)
	@echo "Cleaning up Challenge 4..."
	@kind delete cluster --name $(PRODUCTION_CLUSTER_NAME) 2>/dev/null || true
	@echo "✓ Production cluster deleted"

apply-challenge4-security: ## Apply security controls to production cluster
	@echo "Applying Challenge 4 security controls..."
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) apply -f challenges/challenge4/security/kyverno-policies/
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) apply -f challenges/challenge4/security/network-policies/
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) apply -f challenges/challenge4/security/rbac/least-privilege-argocd.yaml
	@echo "✓ Security controls applied"

test-challenge4-attack: ## Test that Challenge 4 attack payloads are blocked by security controls
	@echo "Testing Challenge 4 attack prevention..."
	@echo ""
	@echo "Test 1: Backdoored deployment (should be BLOCKED by Kyverno)"
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) apply -f challenges/challenge4/attack-payloads/backdoored-deployment.yaml 2>&1 | grep -q "blocked" && echo "  ✓ Blocked by admission policy" || echo "  ❌ Not blocked!"
	@echo ""
	@echo "Test 2: Malicious pod (should be BLOCKED by resource limits)"
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) apply -f challenges/challenge4/attack-payloads/malicious-pod.yaml 2>&1 | grep -q "blocked\|exceeds" && echo "  ✓ Blocked by admission policy" || echo "  ❌ Not blocked!"
	@echo ""
