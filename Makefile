.PHONY: help setup setup-kind setup-gitea setup-tekton setup-tektonchains setup-registry seed-victim-repo setup-ci-pr-pipeline setup-ci-pr-pipeline-secure verify verify-ci-pr-pipeline status clean
.PHONY: setup-security-tools setup-kyverno setup-kubescape security-scan apply-prevention-policies verify-security create-security-policies
.PHONY: check-cli-tools install-tkn install-kubescape install-conforma verify-registry configure-registry-tls verify-tektonchains
.PHONY: setup-conforma verify-conforma
.PHONY: require-registry setup-challenge1 setup-challenge2 build-recipe-api push-recipe-api verify-challenge2 setup-challenge2-tekton trigger-challenge2-build trigger-challenge2-build-with-chains
.PHONY: setup-sigstore-local verify-sigstore-local setup-challenge2-tekton-keyless trigger-challenge2-build-keyless
.PHONY: setup-challenge3 seed-legitimate-base-image verify-challenge3 setup-challenge3-tekton trigger-challenge3-build-with-chains
.PHONY: setup-production-cluster setup-production-gitea setup-production-registry configure-production-registry-tls seed-production-repo load-image-to-production push-recipe-api-to-production setup-argocd setup-e2e-scenario verify-e2e-scenario clean-e2e-scenario apply-challenge4-security test-challenge4-attack
.PHONY: setup-release-pipeline trigger-release-pipeline setup-release-pipeline-secure trigger-release-pipeline-secure trigger-build-with-release-gate
.PHONY: setup-demo setup-gitea-webhooks verify-demo-readiness setup-tekton-dashboard reset-to-challenge1
.PHONY: setup-gateway setup-gateway-production configure-hosts

CLUSTER_NAME ?= ci-cluster
GITEA_HELM_VERSION ?= v12.5.0
TEKTON_PIPELINE_VERSION ?= v0.53.0
TEKTON_CHAINS_VERSION ?= v0.26.3
TEKTON_DASHBOARD_VERSION ?= v0.67.0
CONFORMA_VERSION ?= v0.9.25
KYVERNO_VERSION ?= v3.7.1
KUBESCAPE_VERSION ?= latest
TKN_VERSION ?= v0.44.1
KUBESCAPE_CLI_VERSION ?= v3.0.3
SIGSTORE_SCAFFOLD_VERSION ?= v0.7.24
KNATIVE_VERSION ?= 1.18.0
REGISTRY_PORT ?= 5000
REGISTRY_NODE_PORT ?= 30000
REKOR_NODE_PORT ?= 30006
TUF_NODE_PORT ?= 30007
FULCIO_NODE_PORT ?= 30008
REGISTRY_USER ?= sc-admin
REGISTRY_PASS ?= RegistryPass123!
PRODUCTION_REGISTRY_NODE_PORT ?= 30082
REGISTRY_PROD_DOMAIN ?= registry-prod.sc.local
GATEWAY_PROD_HTTPS_PORT ?= 31443

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
	@if command -v ec >/dev/null 2>&1; then \
		echo "  ✓ ec (Conforma) CLI installed"; \
	else \
		echo "  ⚠ ec CLI not found. Run 'make install-conforma' to install."; \
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

install-conforma: ## Install Conforma (ec) CLI for supply chain policy validation
	@echo "Installing Conforma CLI (ec)..."
	@if command -v ec >/dev/null 2>&1; then \
		echo "  ✓ ec CLI already installed ($$(ec version 2>/dev/null | head -1 || echo 'unknown version'))"; \
		exit 0; \
	fi
	@echo "  Detecting OS and architecture..."
	@OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
	ARCH=$$(uname -m); \
	case $$ARCH in \
		x86_64)         ARCH="amd64" ;; \
		aarch64|arm64)  ARCH="arm64" ;; \
		arm*)           ARCH="arm" ;; \
		*) echo "  ❌ Unsupported architecture: $$ARCH"; exit 1 ;; \
	esac; \
	ASSET="ec_$${OS}_$${ARCH}"; \
	DOWNLOAD_URL="https://github.com/conforma/cli/releases/download/$(CONFORMA_VERSION)/$${ASSET}"; \
	echo "  OS: $$OS, Arch: $$ARCH"; \
	echo "  Downloading $$ASSET from GitHub..."; \
	curl -sSfL "$$DOWNLOAD_URL" -o ec; \
	chmod +x ec; \
	mkdir -p ~/.local/bin; \
	mv ec ~/.local/bin/ec; \
	if ! echo $$PATH | grep -q "$${HOME}/.local/bin"; then \
		echo "  ⚠  Add ~/.local/bin to your PATH:"; \
		echo "     export PATH=\$$PATH:~/.local/bin"; \
	fi; \
	echo "  ✓ ec CLI $(CONFORMA_VERSION) installed at ~/.local/bin/ec"

setup-conforma: install-conforma ## Install Conforma CLI and create EnterpriseContractPolicy on the cluster
	@cd setup && CONFORMA_VERSION=$(CONFORMA_VERSION) ./scripts/setup-conforma.sh

verify-conforma: ## Verify Conforma (ec) CLI installation and signing key
	@echo "Verifying Conforma (ec) installation..."
	@echo ""
	@echo "Conforma CLI:"
	@if command -v ec >/dev/null 2>&1; then \
		echo "  ✓ ec CLI installed: $$(ec version 2>/dev/null | head -1 || echo 'version unknown')"; \
	else \
		echo "  ❌ ec CLI not found (run: make install-conforma)"; \
		exit 1; \
	fi
	@echo ""
	@echo "Signing:"
	@echo "  Tekton Chains uses Fulcio (keyless) — no cosign.pub needed"
	@echo "  Verify with --certificate-identity and --certificate-oidc-issuer"
	@echo ""
	@echo "Example validation command:"
	@echo "  ISSUER=\$$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')"
	@echo "  SSL_CERT_FILE=setup/certs/registry.crt \\"
	@echo "  ec validate image \\"
	@echo "    --images '{\"components\":[{\"name\":\"recipe-api\",\"containerImage\":\"registry.sc.local:30443/recipe-api:v1.0\",\"source\":{\"git\":{\"url\":\"http://gitea-http.gitea.svc.cluster.local:3000/sc-admin/recipe-api.git\",\"revision\":\"9d81c465f358fef7efd791966e482e1eece4ff78\"}}}]}' \\"
	@echo "    --certificate-identity https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller \\"
	@echo "    --certificate-oidc-issuer \$$ISSUER \\"
	@echo "    --rekor-url http://rekor.sc.local:30080 \\"
	@echo "    --policy '{\"sources\":[{\"name\":\"sc-minimal\",\"policy\":[\"github.com/conforma/policy//policy/lib\",\"github.com/conforma/policy//policy/release\"],\"config\":{\"include\":[\"@minimal\"],\"exclude\":[\"base_image_registries.base_image_info_found\",\"cve.cve_results_found\"]}}]}' \\"
	@echo "    --extra-rule-data allowed_registry_prefixes=registry.registry.svc.cluster.local:5000 \\"
	@echo "    --extra-rule-data allowed_registry_prefixes=registry.sc.local:30443 \\"
	@echo "    --extra-rule-data allowed_registry_prefixes=docker.io \\"
	@echo "    --extra-rule-data allowed_registry_prefixes=gcr.io \\"
	@echo "    --extra-rule-data allowed_registry_prefixes=golang \\"
	@echo "    --output text"

# ============================================================
# Help and Setup
# ============================================================

help: ## Display this help message
	@echo "Supply Chain Deep Dive Environment - Available Commands:"
	@echo ""
	@echo "🚀 Quick Start (Deep Dive Demo):"
	@echo "  \033[36mmake setup-demo\033[0m              Complete automated setup for Challenges 1-4"
	@echo "  \033[36mmake verify-demo-readiness\033[0m   Verify all prerequisites are met"
	@echo "  See DEMO-SETUP.md for detailed instructions"
	@echo ""
	@echo "CLI Tools:"
	@grep -E '^(check-cli-tools|install-tkn|install-kubescape|install-conforma):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Environment Setup:"
	@grep -E '^(setup|setup-kind|setup-gitea|setup-tekton|setup-tekton-dashboard|setup-tektonchains|setup-registry|configure-registry-tls|seed-victim-repo|setup-ci-pr-pipeline|setup-ci-pr-pipeline-secure|setup-gitea-webhooks):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Security Tools:"
	@grep -E '^(setup-security-tools|setup-kyverno|setup-kubescape|setup-conforma):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Security Operations:"
	@grep -E '^(create-security-policies|apply-prevention-policies|security-scan|verify-security):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Verification:"
	@grep -E '^(verify|verify-ci-pr-pipeline|verify-registry|verify-tektonchains|verify-conforma|verify-demo-readiness|status):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Cleanup:"
	@grep -E '^(clean):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick Start (Manual Steps):"
	@echo "  1. make check-cli-tools          # Check for required CLI tools"
	@echo "  2. make setup                    # Setup complete deep dive environment"
	@echo "  3. make configure-registry-tls   # Configure registry TLS trust"
	@echo "  4. make setup-ci-pr-pipeline      # Setup Challenge 1"
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

setup: check-cli-tools configure-hosts setup-kind setup-gitea setup-tekton setup-registry setup-gateway configure-registry-tls verify ## Complete setup (KinD cluster + Gitea + tekton + registry + gateway + verification)
	@echo ""
	@echo "✓ Setup complete! Next steps:"
	@echo "  • Run 'make setup-ci-pr-pipeline' to install CI pipeline resources"
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

setup-tekton-dashboard: ## Install Tekton Dashboard (web UI)
	@cd setup && ./scripts/setup-tekton-dashboard.sh

setup-tektonchains: ## Install and configure Tekton Chains for supply chain security
	@cd setup && ./scripts/setup-tektonchains.sh
	@echo ""
	@if kubectl get configmap registry-ca-cert -n ci &>/dev/null; then \
		echo "Setting up registry trust for Tekton Chains..."; \
		cd setup && ./scripts/setup-tektonchains-registry-trust.sh; \
	else \
		echo "⚠️  Registry CA cert not found. Tekton Chains may not be able to access the local registry."; \
		echo "   Run 'make setup-registry' first if you haven't already."; \
	fi
	@echo ""
	@echo "💡 Tekton Chains is now configured with:"
	@echo "   • Format: in-toto (AMPEL/Conforma compatible)"
	@echo "   • Storage: OCI registry"
	@echo "   • Deep inspection: enabled"
	@echo "   • Registry trust: configured (if registry exists)"
	@echo ""
	@echo "Next steps:"
	@echo "   • Run pipelines to automatically generate attestations"
	@echo "   • Verify installation: make verify-tektonchains"
	@echo ""

setup-registry: ## Setup local Docker registry with authentication
	@cd setup && ./scripts/setup-registry.sh

configure-registry-tls: ## Configure TLS trust for the registry (interactive)
	@./setup/scripts/configure-registry-tls.sh

require-registry: ## Verify the registry is deployed and running (fails with instructions if not)
	@kubectl get deployment/registry -n registry &>/dev/null && \
	 kubectl wait --for=condition=available --timeout=5s deployment/registry -n registry &>/dev/null || \
	 { echo "Error: Registry is not running."; \
	   echo "Run 'make setup-registry' (or 'make setup') first."; \
	   exit 1; }

setup-gateway: ## Deploy Gateway API with Envoy Gateway for *.sc.local domains (ci cluster)
	@cd setup && ./scripts/setup-gateway.sh ci

setup-gateway-production: ## Deploy Gateway API with Envoy Gateway for *.sc.local domains (production cluster)
	@cd setup && ./scripts/setup-gateway.sh production

configure-hosts: ## Configure /etc/hosts for *.sc.local domain resolution
	@./setup/scripts/configure-hosts.sh

seed-victim-repo: ## Seed recipe-api repository to CI cluster Gitea
	@./setup/scripts/seed-victim-repo.sh

setup-ci-pr-pipeline: seed-victim-repo ## Install Tekton deep dive challenge resources (VULNERABLE version)
	@echo "Installing Tekton Deep Dive Challenge (VULNERABLE version)..."
	@kubectl create namespace ci 2>/dev/null || true
	@echo ""	
	@echo "Setting up registry CA certificate for Tekton..."
	@cd setup/scripts && ./setup-registry-cert-for-tekton.sh
	@echo ""
	@kubectl apply -f challenges/challenge1/tekton/triggers/vulnerable-eventlistener.yaml
	@kubectl apply -f challenges/challenge1/tekton/tasks/supporting-tasks.yaml
	@kubectl apply -f challenges/challenge1/tekton/tasks/vulnerable-quality-check-task.yaml
	@kubectl apply -f challenges/challenge1/tekton/pipelines/vulnerable-pr-quality-pipeline.yaml
	@echo ""
	@echo "Creating registry credentials secret with registry credentials..."
	@kubectl create secret generic registry-credentials \
		--from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
		--from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
		--from-literal=registry-user='$(REGISTRY_USER)' \
		--from-literal=registry-password='$(REGISTRY_PASS)' \
		-n ci --dry-run=client -o yaml | kubectl apply -f -
	
	@echo "Next steps:"
	@echo "  1. Complete victim repository setup: challenges/challenge1/SETUP.md"
	@echo "  2. Review the challenge guide: challenges/challenge1/ATTACK-GUIDE.md"
	@echo "  3. Test the attack: make verify-ci-pr-pipeline"
	@echo ""
	@echo "To deploy SECURE version instead:"
	@echo "  make setup-ci-pr-pipeline-secure"

setup-ci-pr-pipeline-secure: ## Install Tekton deep dive challenge with SECURE configuration
	@echo "Installing Tekton Deep Dive Challenge (SECURE version)..."
	@kubectl create namespace ci 2>/dev/null || true
	@echo ""
	@echo "Step 1: Deploying security RBAC (minimal ServiceAccounts)..."
	@kubectl apply -f challenges/challenge1/security/rbac/minimal-serviceaccounts.yaml
	@echo ""
	@echo "Step 2: Deploying secure Tekton resources..."
	@kubectl apply -f challenges/challenge1/tekton-patched/tasks/
	@kubectl apply -f challenges/challenge1/tekton-patched/pipelines/
	@kubectl apply -f challenges/challenge1/tekton-patched/triggers/
	@echo ""
	@echo "Step 3: Creating registry credentials secret with registry credentials..."
	@kubectl create secret generic registry-credentials \
		--from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
		--from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
		--from-literal=registry-user='$(REGISTRY_USER)' \
		--from-literal=registry-password='$(REGISTRY_PASS)' \
		-n ci --dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "✓ Deep Dive Challenge installed successfully (SECURE version)"
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
	@echo "Verifying deep dive environment..."
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
	@echo "Deep Dive Environment Status"
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
	@echo "Tekton Dashboard:"
	@kubectl get pods -n tekton-pipelines -l app.kubernetes.io/part-of=tekton-dashboard 2>/dev/null || echo "  Tekton Dashboard not installed (run: make setup-tekton-dashboard)"
	@echo ""
	@echo "Access URLs:"
	@echo "  Gitea:            http://gitea.sc.local:30080"
	@echo "  Tekton Dashboard: http://dashboard.sc.local:30080"
	@echo "  Registry:         https://registry.sc.local:30443"

verify-ci-pr-pipeline: ## Verify Tekton deep dive challenge installation
	@echo "Verifying Tekton Deep Dive Challenge..."
	@echo ""
	@echo "Tekton Pipelines:"
	@kubectl get pods -n tekton-pipelines 2>/dev/null || echo "  ❌ Tekton not installed (run: make setup-tekton)"
	@echo ""
	@echo "CI Pipeline:"
	@kubectl get pipeline pr-quality-check-pipeline -n ci 2>/dev/null || echo "  ❌ Pipeline not found (run: make setup-ci-pr-pipeline)"
	@echo ""
	@echo "CI Tasks:"
	@kubectl get task quality-check-task git-clone print-info print-results -n ci 2>/dev/null || echo "  ❌ Tasks not found"
	@echo ""
	@echo "EventListener:"
	@kubectl get eventlistener pr-quality-check-listener -n ci 2>/dev/null || echo "  ❌ EventListener not found"
	@echo ""
	@echo "Registry Credentials Secret:"
	@kubectl get secret registry-credentials -n ci 2>/dev/null && echo "  ✓ Flag secret exists" || echo "  ❌ Flag secret not found"
	@echo ""
	@echo "ServiceAccounts:"
	@kubectl get sa tekton-triggers-sa default -n ci 2>/dev/null || echo "  ❌ ServiceAccounts not found"
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
	@curl -k -sf -u $(REGISTRY_USER):$(REGISTRY_PASS) https://registry.sc.local:30443/v2/_catalog 2>/dev/null && \
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
	        --set kubescape.resources.requests.memory=800Mi \
                --set kubescape.resources.limits.memory=1500Mi \
                --set kubescape.resources.requests.cpu=500m \
                --set kubescape.resources.limits.cpu=1000m
	#	--set capabilities.continuousScan=enable \
	#	--set capabilities.runtimeObservability=disable \
	#	--set capabilities.runtimeDetection=disable \
	#	--set capabilities.malwareDetection=disable \
	#	--set capabilities.nodeProfileService=disable \
	#	--set capabilities.networkPolicyService=disable \
	#	--set capabilities.networkEventsStreaming=disable \
	#	--set capabilities.nodeSbomGeneration=disable \
	#	--wait --timeout=5m
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
	@echo "ServiceAccounts (Deep Dive Challenge):"
	@echo "------------------------------------------------"
	@kubectl get sa -n ci 2>/dev/null || echo "  deep dive challenge not set up"
	@echo ""
	@echo "✓ Security verification complete"
# ============================================================
# Challenge 2: Container Image Layer Leak
# ============================================================

setup-challenge2: require-registry seed-legitimate-base-image build-recipe-api push-recipe-api ## Setup Challenge 2 (container layer leak)
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
	@echo "  Rewriting Dockerfile FROM to use host-accessible registry..."
	@sed -i 's|registry.registry.svc.cluster.local:5000|registry.sc.local:30443|g' /tmp/recipe-api-build/Dockerfile
	@echo "  Building image with leaked git history..."
	@cd /tmp/recipe-api-build && \
		$(CONTAINER_RUNTIME) build -t registry.sc.local:30443/recipe-api:v1.0 -f Dockerfile . 2>&1 | grep -E "(STEP|Successfully|Error)" || true
	@echo "✓ Image built successfully with .git in layers"
	@echo "  Note: /tmp/recipe-api-build contains the build context (you can inspect it)"

push-recipe-api: ## Push recipe-api image to registry
	@echo "Pushing recipe-api:v1.0 to registry..."
	@$(CONTAINER_RUNTIME) login registry.sc.local:30443 \
		-u $(REGISTRY_USER) -p $(REGISTRY_PASS) 2>/dev/null || true
	@$(CONTAINER_RUNTIME) push registry.sc.local:30443/recipe-api:v1.0
	@echo "✓ Image pushed to registry"

verify-challenge2: ## Verify Challenge 2 setup
	@echo "Verifying Challenge 2 setup..."
	@cd challenges/challenge2 && ./test-attack2.sh

setup-challenge2-tekton: ## Setup Challenge 2 Tekton pipeline resources
	@echo "========================================"
	@echo "Installing Challenge 2 Tekton Resources"
	@echo "========================================"
	@kubectl create namespace ci 2>/dev/null || true
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
	@echo "Creating registry credentials secret with registry credentials (if not exists)..."
	@kubectl create secret generic registry-credentials \
		--from-literal=flag='FLAG{t3kt0n_pwn_r3qu3st_1s_d4ng3r0us}' \
		--from-literal=registry-url='https://registry.registry.svc.cluster.local:5000' \
		--from-literal=registry-user='$(REGISTRY_USER)' \
		--from-literal=registry-password='$(REGISTRY_PASS)' \
		-n ci --dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "Tekton Chains uses Fulcio for keyless signing (no cosign.pub needed)."
	@echo "  Verify with: cosign verify --certificate-identity=... --certificate-oidc-issuer=..."
	@echo ""
	@echo "✓ Challenge 2 Tekton resources installed successfully"
	@echo ""
	@echo "Pipelines available:"
	@echo "  push-build-pipeline             — original build + push"
	@echo "  push-build-pipeline-with-chains — build + push + sign + SBOM"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Trigger original pipeline:      make trigger-challenge2-build"
	@echo "  2. Trigger Chains+SBOM pipeline:    make trigger-challenge2-build-with-chains"
	@echo "  3. Monitor pipeline runs:          kubectl get pipelineruns -n ci"
	@if command -v kubectl-tkn >/dev/null 2>&1; then \
		echo "  4. View logs: kubectl tkn pipelinerun logs -f -n ci"; \
	elif command -v tkn >/dev/null 2>&1; then \
		echo "  4. View logs: tkn pipelinerun logs -f -n ci"; \
	else \
		echo "  4. Install tkn for easier log viewing: make install-tkn"; \
	fi

trigger-challenge2-build: ## Trigger Challenge 2 pipeline to build and push image
	@echo "========================================"
	@echo "Triggering Challenge 2 Build Pipeline"
	@echo "========================================"
	@echo ""
	@if ! kubectl get pipeline push-build-pipeline -n ci >/dev/null 2>&1; then \
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
	@echo "    kubectl get pipelineruns -n ci -w"
	@echo ""
	@if command -v kubectl-tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    kubectl tkn pipelinerun logs -f -n ci"; \
	elif command -v tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    tkn pipelinerun logs -f -n ci"; \
	else \
		echo "  Install tkn for easier log viewing:"; \
		echo "    make install-tkn"; \
	fi
	@echo ""
	@echo "✓ Pipeline triggered successfully"
	@echo ""
	@echo "Image will be pushed to: registry.registry.svc.cluster.local:5000/recipe-api:latest"

trigger-challenge2-build-secure: ## Trigger Challenge 2 pipeline to build and push image
	@echo "========================================"
	@echo "Triggering Challenge 2 Build Pipeline (Secure)"
	@echo "========================================"
	@echo ""
	@if ! kubectl get pipeline push-build-pipeline-secure -n ci >/dev/null 2>&1; then \
		echo "❌ Pipeline not found. Run 'kubectl apply -f supply-chain-dd/challenges/challenge2/tekton-patched/pipelines/push-build-pipeline-secure.yaml' first"; \
		exit 1; \
	fi
	@echo "Starting pipeline run..."
	@kubectl create -f challenges/challenge2/tekton-patched/manual-pipelinerun-secure.yaml
	@echo ""
	@echo "  ✓ PipelineRun created"
	

trigger-challenge2-build-with-chains: ## Trigger Challenge 2 Chains pipeline (build + push + sign + SBOM)
	@echo "========================================"
	@echo "Triggering Challenge 2 Build Pipeline (with Chains + SBOM)"
	@echo "========================================"
	@echo ""
	@if ! kubectl get pipeline push-build-pipeline-with-chains -n ci >/dev/null 2>&1; then \
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
	@echo "Starting pipeline run (push-build-pipeline-with-chains)..."
	@kubectl create -f challenges/challenge2/tekton/manual-pipelinerun-with-chains.yaml
	@echo ""
	@echo "  ✓ PipelineRun created (push-build-pipeline-with-chains)"
	@echo ""
	@echo "  Pipeline stages:"
	@echo "    1. verify-source               — validate repo URL + branch containment"
	@echo "    2. clone-repo                  — fetch source from Gitea"
	@echo "    3. build-go-app                — compile Go binary"
	@echo "    4. run-quality-checks          — static analysis"
	@echo "    5. build-container-image       — kaniko build"
	@echo "    6. push-container-image        — push + emit IMAGE_URL/IMAGE_DIGEST"
	@echo "       [Tekton Chains auto-signs image and creates SLSA attestation]"
	@echo "    7. create-source-vsa           — attach unsigned Source VSA via OCI referrers"
	@echo "    8. generate-sbom               — Trivy SPDX SBOM + oras attach"
	@echo ""
	@echo "  Monitor with:"
	@echo "    kubectl get pipelineruns -n ci -w"
	@if command -v kubectl-tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    kubectl tkn pipelinerun logs -f -n ci"; \
	elif command -v tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    tkn pipelinerun logs -f -n ci"; \
	else \
		echo "  Install tkn for easier log viewing:"; \
		echo "    make install-tkn"; \
	fi

# ============================================================
# Sigstore Local Stack + Keyless Signing
# ============================================================

setup-sigstore-local: ## Deploy local Sigstore stack (Fulcio, Rekor, TUF) on KinD
	@cd setup && SIGSTORE_SCAFFOLD_VERSION=$(SIGSTORE_SCAFFOLD_VERSION) KNATIVE_VERSION=$(KNATIVE_VERSION) ./scripts/setup-sigstore-local.sh

verify-sigstore-local: ## Verify local Sigstore stack is running
	@echo "Verifying local Sigstore stack..."
	@echo ""
	@echo "Fulcio (CA):"
	@kubectl get pods -n fulcio-system 2>/dev/null || echo "  ❌ Fulcio not deployed"
	@echo ""
	@echo "Rekor (transparency log):"
	@kubectl get pods -n rekor-system 2>/dev/null || echo "  ❌ Rekor not deployed"
	@echo ""
	@echo "TUF (root of trust):"
	@kubectl get pods -n tuf-system 2>/dev/null || echo "  ❌ TUF not deployed"
	@echo ""
	@echo "TUF root ConfigMap:"
	@kubectl get configmap sigstore-tuf-root -n ci 2>/dev/null && echo "  ✓ sigstore-tuf-root exists in ci" || echo "  ❌ sigstore-tuf-root not found"
	@echo ""
	@echo "OIDC issuer:"
	@kubectl get --raw /.well-known/openid-configuration 2>/dev/null | jq -r '.issuer' || echo "  ❌ Could not retrieve OIDC issuer"

setup-challenge2-tekton-keyless: ## Deploy keyless signing pipeline for Challenge 2
	@echo "========================================"
	@echo "Installing Challenge 2 Keyless Signing"
	@echo "========================================"
	@echo ""
	@echo "Setting up keyless signer ServiceAccount..."
	@kubectl apply -f challenges/challenge2/tekton/serviceaccounts-keyless.yaml
	@echo ""
	@echo "Applying sign-image-keyless task..."
	@kubectl apply -f challenges/challenge2/tekton/tasks/sign-image-keyless-task.yaml
	@echo ""
	@echo "Applying keyless signing pipeline..."
	@kubectl apply -f challenges/challenge2/tekton/pipelines/push-build-pipeline-keyless.yaml
	@echo ""
	@echo "✓ Keyless signing pipeline installed"
	@echo ""
	@echo "Pipeline: push-build-pipeline-keyless"
	@echo "  Uses cosign keyless signing via local Fulcio + Rekor"
	@echo "  SA: pipeline-keyless-signer (projected token as OIDC identity)"
	@echo ""
	@echo "Next: make trigger-challenge2-build-keyless"

trigger-challenge2-build-keyless: ## Trigger Challenge 2 keyless signing pipeline
	@echo "========================================"
	@echo "Triggering Challenge 2 Keyless Build Pipeline"
	@echo "========================================"
	@echo ""
	@if ! kubectl get pipeline push-build-pipeline-keyless -n ci >/dev/null 2>&1; then \
		echo "❌ Pipeline not found. Run 'make setup-challenge2-tekton-keyless' first"; \
		exit 1; \
	fi
	@echo "Starting pipeline run (push-build-pipeline-keyless)..."
	@kubectl create -f challenges/challenge2/tekton/manual-pipelinerun-keyless.yaml
	@echo ""
	@echo "  ✓ PipelineRun created (push-build-pipeline-keyless)"
	@echo ""
	@echo "  Pipeline stages:"
	@echo "    1. verify-source          — validate repo URL + branch containment"
	@echo "    2. clone-repo             — fetch source from Gitea"
	@echo "    3. build-go-app           — compile Go binary"
	@echo "    4. run-quality-checks     — static analysis"
	@echo "    5. push-container-image   — push + emit IMAGE_URL/IMAGE_DIGEST"
	@echo "    6. sign-image-keyless     — cosign keyless sign (Fulcio + Rekor)"
	@echo "       [Tekton Chains still generates SLSA provenance in background]"
	@echo "    7. create-source-vsa      — attach unsigned Source VSA"
	@echo "    8. generate-sbom          — Trivy SPDX SBOM + oras attach"
	@echo "    9. scan-image             — Trivy vuln+secret scan + oras attach"
	@echo ""
	@echo "  Monitor with:"
	@echo "    kubectl get pipelineruns -n ci -w"
	@if command -v kubectl-tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    kubectl tkn pipelinerun logs -f -n ci"; \
	elif command -v tkn >/dev/null 2>&1; then \
		echo "  View logs:"; \
		echo "    tkn pipelinerun logs -f -n ci"; \
	else \
		echo "  Install tkn for easier log viewing:"; \
		echo "    make install-tkn"; \
	fi

# ============================================================
# Deep Dive Demo Setup (Challenges 1-4)
# ============================================================

setup-demo: setup configure-registry-tls seed-legitimate-base-image setup-security-tools setup-ci-pr-pipeline setup-sigstore-local setup-tektonchains setup-challenge2-tekton setup-gitea-webhooks trigger-challenge2-build build-recipe-api push-recipe-api setup-e2e-scenario setup-release-pipeline configure-production-registry-tls verify-demo-readiness ## Complete automated setup for deep dive demo (Challenges 1-4)
	@echo ""
	@echo "Restoring kubectl context to CI cluster..."
	@kubectl config use-context kind-$(CLUSTER_NAME)
	@echo ""
	@echo "=========================================="
	@echo "✓ Deep Dive Demo Environment Ready!"
	@echo "=========================================="
	@echo ""
	@echo "Access Information:"
	@echo "  CI Cluster:"
	@echo "    Gitea:            http://gitea.sc.local:30080"
	@echo "    Tekton Dashboard: http://dashboard.sc.local:30080"
	@echo "    Registry:         https://registry.sc.local:30443"
	@echo "    Username: sc-admin"
	@echo "    Password: SecurePass123!"
	@echo ""
	@echo "  Production Cluster (Challenge 4):"
	@echo "    Gitea:    http://gitea-prod.sc.local:31080"
	@echo "    ArgoCD:   http://argocd.sc.local:31080"
	@echo "    Username: sc-admin / admin (ArgoCD)"
	@echo "    Password: SecurePass123! / admin123 (ArgoCD)"
	@echo ""
	@echo "Challenges Ready:"
	@echo "  • Challenge 1: PR Quality Check Attack"
	@echo "  • Challenge 2: Container Layer Leak Attack"
	@echo "  • Challenge 3: Base Image Poisoning Attack"
	@echo "  • Challenge 4: GitOps Pipeline Compromise"
	@echo ""
	@echo "Start the Demo:"
	@echo "  1. Open Gitea: http://gitea.sc.local:30080"
	@echo "  2. Create a pull request in recipe-api repository"
	@echo "  3. Follow attack guides in challenges/challengeN/ATTACK-GUIDE.md"
	@echo "  4. Monitor pipelines: kubectl get pipelineruns -n ci -w"
	@echo ""

setup-gitea-webhooks: ## Setup Gitea webhooks for Tekton EventListeners
	@./setup/scripts/setup-gitea-webhooks.sh

verify-demo-readiness: ## Verify all prerequisites for deep dive demo are met
	@./setup/scripts/verify-demo-readiness.sh

reset-to-challenge1: ## Reset environment to Challenge 1 starting state (vulnerable PR pipeline)
	@./setup/scripts/reset-to-challenge1.sh

# ============================================================
# Challenge 3: Malware in Base Image
# ============================================================

setup-challenge3: require-registry ## Setup Challenge 3 (base image poisoning)
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
	@echo "  • Victim repository Dockerfile uses registry.sc.local:30443/golang:1.25-alpine"
	@echo ""
	@echo "Attack Scenario:"
	@echo "  1. Create malicious base image with backdoor"
	@echo "  2. Push poisoned image to registry (overwrites legitimate base)"
	@echo "  3. Trigger build pipeline"
	@echo "  4. Malware embedded in recipe-api production image"
	@echo ""
	@echo "Next Steps:"
	@echo "  1. Follow setup: challenges/challenge3/SETUP.md"
	@echo "  2. Execute attack: challenges/challenge3/ATTACK-GUIDE.md"
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
	@echo "  Tagging as registry.sc.local:30443/golang:1.25-alpine..."
	@$(CONTAINER_RUNTIME) tag golang:1.25-alpine registry.sc.local:30443/golang:1.25-alpine
	@echo "  Logging in to registry..."
	@$(CONTAINER_RUNTIME) login registry.sc.local:30443 \
		-u $(REGISTRY_USER) -p $(REGISTRY_PASS) 2>/dev/null || true
	@echo "  Pushing to registry..."
	@$(CONTAINER_RUNTIME) push registry.sc.local:30443/golang:1.25-alpine
	@echo "✓ Legitimate base image seeded to registry"
	@echo ""
	@echo "Seeding runtime base image (alpine:3.20)..."
	@if ! $(CONTAINER_RUNTIME) images | grep -q "alpine.*3.20"; then \
		echo "  Pulling alpine:3.20..."; \
		$(CONTAINER_RUNTIME) pull alpine:3.20; \
	else \
		echo "  ✓ alpine:3.20 already pulled"; \
	fi
	@echo "  Tagging as registry.sc.local:30443/alpine:3.20..."
	@$(CONTAINER_RUNTIME) tag alpine:3.20 registry.sc.local:30443/alpine:3.20
	@echo "  Pushing to registry..."
	@$(CONTAINER_RUNTIME) push registry.sc.local:30443/alpine:3.20
	@echo "✓ Runtime base image seeded to registry"

verify-challenge3: ## Verify Challenge 3 setup
	@echo "Verifying Challenge 3 setup..."
	@echo ""
	@echo "Registry Status:"
	@kubectl get pods,svc -n registry 2>/dev/null || { echo "  ❌ Registry not running (run: make setup-registry)"; exit 1; }
	@echo ""
	@echo "Base Image in Registry:"
	@if curl --cacert setup/certs/registry.crt -s -u $(REGISTRY_USER):$(REGISTRY_PASS) \
		https://registry.sc.local:30443/v2/golang/tags/list 2>/dev/null | grep -q "1.25-alpine"; then \
		echo "  ✓ golang:1.25-alpine exists in registry"; \
	else \
		echo "  ❌ Base image not found (run: make seed-legitimate-base-image)"; \
		exit 1; \
	fi
	@echo ""
	@echo "Victim Dockerfile Configuration:"
	@if grep -q "FROM.*golang:1.25-alpine" challenges/victim-repo-sample/Dockerfile; then \
		echo "  ✓ Dockerfile uses local registry base image"; \
	else \
		echo "  ❌ Dockerfile not configured for challenge3"; \
		exit 1; \
	fi
	@echo ""
	@echo "Registry Credentials (from Challenge 1):"
	@echo "  URL:      https://registry.sc.local:30443"
	@echo "  Username: $(REGISTRY_USER)"
	@echo "  Password: $(REGISTRY_PASS)"
	@echo ""
	@echo "✓ Challenge 3 environment ready"
	@echo ""
	@echo "Next: Follow challenges/challenge3/ATTACK-GUIDE.md to execute the attack"

setup-challenge3-tekton: ## Deploy Challenge 3 Tekton resources (enhanced pipeline with vuln scan + SBOM + full provenance)
	@echo ""
	@echo "============================================"
	@echo "Setting up Challenge 3 Tekton pipeline"
	@echo "============================================"
	@echo ""
	@echo "Deploying tasks..."
	@kubectl apply -f challenges/challenge3/tekton/tasks/
	@echo ""
	@echo "Deploying pipeline..."
	@kubectl apply -f challenges/challenge3/tekton/pipelines/
	@echo ""
	@echo "Pipeline: push-build-pipeline-with-chains (enhanced)"
	@echo "  Post-push tasks:"
	@echo "    - create-source-vsa       (Source VSA -> provenance subject)"
	@echo "    - scan-image              (Secret scan -> provenance subject)"
	@echo "    - scan-vulnerabilities    (Vuln scan -> provenance subject)"
	@echo "    - generate-sbom           (SBOM -> provenance subject)"
	@echo ""
	@echo "Trigger with: make trigger-challenge3-build-with-chains"

trigger-challenge3-build-with-chains: ## Run Challenge 3 enhanced pipeline (Tekton Chains + vuln scan + SBOM)
	@echo "Triggering Challenge 3 enhanced pipeline..."
	@kubectl create -f challenges/challenge3/tekton/manual-pipelinerun-with-chains.yaml
	@echo ""
	@echo "Monitor with: kubectl get pipelineruns -n ci -w"

setup-challenge3-tekton-secure: ## Deploy Challenge 3 secured Tekton resources (base image verification + keyless signing)
	@echo ""
	@echo "============================================"
	@echo "Setting up Challenge 3 SECURED pipeline"
	@echo "============================================"
	@echo ""
	@echo "Deploying secured tasks..."
	@kubectl apply -f challenges/challenge3/tekton-patched/tasks/
	@echo ""
	@echo "Deploying secured pipeline..."
	@kubectl apply -f challenges/challenge3/tekton-patched/pipelines/
	@echo ""
	@echo "Deploying webhook trigger..."
	@kubectl apply -f challenges/challenge3/tekton-patched/triggers/
	@echo ""
	@echo "Deploying baseline SBOM ConfigMap..."
	@kubectl apply -f challenges/challenge3/security/configmaps/
	@echo ""
	@echo "Secured pipeline: push-build-pipeline-with-chains-secure"
	@echo "  Pre-build tasks:"
	@echo "    - verify-base-image        (Registry, digest, SBOM, baseline check)"
	@echo "  Post-push tasks:"
	@echo "    - sign-image-keyless       (Cosign keyless via Fulcio)"
	@echo "    - create-source-vsa        (Source VSA -> provenance subject)"
	@echo "    - scan-image               (Secret scan -> provenance subject)"
	@echo "    - scan-vulnerabilities     (Vuln scan -> provenance subject)"
	@echo "    - generate-sbom            (SBOM -> provenance subject)"
	@echo "    - attest-sbom              (Signed SBOM attestation via cosign attest)"
	@echo ""
	@echo "Trigger with: make trigger-challenge3-build-secure"

trigger-challenge3-build-secure: ## Run Challenge 3 secured pipeline manually
	@echo "Triggering Challenge 3 secured pipeline..."
	@kubectl create -f challenges/challenge3/tekton-patched/manual-pipelinerun-with-chains-secure.yaml
	@echo ""
	@echo "Monitor with: kubectl get pipelineruns -n ci -w"

install-ampel: ## Install Ampel CLI for post-pipeline policy verification
	@echo "Installing Ampel CLI..."
	@go install github.com/carabiner-dev/ampel/cmd/ampel@latest
	@echo "✓ Ampel installed"

install-syft: ## Install Syft CLI for SBOM generation
	@echo "Installing Syft CLI..."
	@curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b $$(go env GOPATH)/bin
	@echo "✓ Syft installed"

# ============================================================
# Challenge 4: GitOps Pipeline Compromise
# ============================================================

PRODUCTION_CLUSTER_NAME ?= production-cluster
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

setup-production-registry: ## Setup Docker registry on production cluster
	@cd setup && ./scripts/setup-production-registry.sh

configure-production-registry-tls: ## Configure TLS trust for the production registry (interactive)
	@REGISTRY_DOMAIN=$(REGISTRY_PROD_DOMAIN) GATEWAY_HTTPS_PORT=$(GATEWAY_PROD_HTTPS_PORT) REGISTRY_KUBECTL_CONTEXT=kind-$(PRODUCTION_CLUSTER_NAME) ./setup/scripts/configure-registry-tls.sh setup/certs/production-registry.crt

push-recipe-api-to-production: ## Copy recipe-api image from CI registry to production registry
	@echo "Copying recipe-api:v1.0 from CI registry to production registry..."
	@skopeo copy \
		--src-tls-verify=false \
		--dest-tls-verify=false \
		--src-creds $(REGISTRY_USER):$(REGISTRY_PASS) \
		--dest-creds $(REGISTRY_USER):$(REGISTRY_PASS) \
		docker://registry.sc.local:30443/recipe-api:v1.0 \
		docker://registry-prod.sc.local:31443/recipe-api:v1.0
	@echo "✓ recipe-api:v1.0 copied to production registry (registry-prod.sc.local:31443)"

load-image-to-production: ## Load recipe-api image into production cluster (legacy)
	@./setup/scripts/load-image-to-production.sh

setup-argocd: ## Install ArgoCD on production cluster
	@./setup/scripts/setup-argocd.sh

setup-release-pipeline: ## Deploy release pipeline resources (namespace, tasks, pipeline, triggers)
	@echo "========================================"
	@echo "Setting up Release Pipeline"
	@echo "========================================"
	@kubectl --context kind-$(CLUSTER_NAME) create namespace release-pipeline 2>/dev/null || true
	@echo "Creating CI registry credentials in release-pipeline namespace..."
	@kubectl --context kind-$(CLUSTER_NAME) create secret docker-registry ci-registry-credentials \
		--docker-server=registry.registry.svc.cluster.local:5000 \
		--docker-username=$(REGISTRY_USER) \
		--docker-password=$(REGISTRY_PASS) \
		-n release-pipeline --dry-run=client -o yaml | kubectl --context kind-$(CLUSTER_NAME) apply -f -
	@echo "Creating production registry credentials in release-pipeline namespace..."
	@kubectl --context kind-$(CLUSTER_NAME) create secret docker-registry production-registry-credentials \
		--docker-server=registry-prod.sc.local:31443 \
		--docker-username=$(REGISTRY_USER) \
		--docker-password=$(REGISTRY_PASS) \
		-n release-pipeline --dry-run=client -o yaml | kubectl --context kind-$(CLUSTER_NAME) apply -f -
	@echo "Creating CI registry CA cert ConfigMap..."
	@kubectl --context kind-$(CLUSTER_NAME) create configmap ci-registry-ca-cert \
		--from-file=ca.crt=setup/certs/registry.crt \
		-n release-pipeline --dry-run=client -o yaml | kubectl --context kind-$(CLUSTER_NAME) apply -f -
	@if [ -f setup/certs/production-registry.crt ]; then \
		echo "Creating production registry CA cert ConfigMap..."; \
		kubectl --context kind-$(CLUSTER_NAME) create configmap production-registry-ca-cert \
			--from-file=ca.crt=setup/certs/production-registry.crt \
			-n release-pipeline --dry-run=client -o yaml | kubectl --context kind-$(CLUSTER_NAME) apply -f -; \
	fi
	@echo "Creating production Gitea credentials..."
	@kubectl --context kind-$(CLUSTER_NAME) create secret generic production-gitea-credentials \
		--from-literal=username=sc-admin \
		--from-literal=password=SecurePass123! \
		-n release-pipeline --dry-run=client -o yaml | kubectl --context kind-$(CLUSTER_NAME) apply -f -
	@echo "Applying Tekton release pipeline resources..."
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/e2e-scenario/tekton/release-namespace.yaml
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/e2e-scenario/tekton/tasks/release-tasks.yaml
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/e2e-scenario/tekton/pipelines/release-pipeline.yaml
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/e2e-scenario/tekton/triggers/release-eventlistener.yaml
	@echo "✓ Release pipeline resources deployed in release-pipeline namespace"

trigger-release-pipeline: ## Manually trigger the release pipeline
	@kubectl --context kind-$(CLUSTER_NAME) create -f challenges/e2e-scenario/tekton/manual-release-pipelinerun.yaml
	@echo "✓ Release pipeline triggered. Monitor: kubectl get pipelineruns -n release-pipeline -w"

setup-release-pipeline-secure: setup-release-pipeline ## Deploy secured release pipeline with Conforma verification gate
	@echo "========================================"
	@echo "Setting up Secured Release Pipeline"
	@echo "========================================"
	@echo "Copying sigstore-tuf-root ConfigMap to release-pipeline namespace..."
	@kubectl --context kind-$(CLUSTER_NAME) get configmap sigstore-tuf-root -n ci -o json | \
		jq '.metadata.namespace = "release-pipeline" | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)' | \
		kubectl --context kind-$(CLUSTER_NAME) apply -f -
	@echo "Creating Conforma SBOM policy ConfigMap in release-pipeline namespace..."
	@kubectl --context kind-$(CLUSTER_NAME) create configmap conforma-sbom-policy \
		--from-file=sbom-baseline-check.rego=challenges/challenge3/security/conforma-policies/sbom-baseline-check.rego \
		-n release-pipeline --dry-run=client -o yaml | kubectl --context kind-$(CLUSTER_NAME) apply -f -
	@echo "Applying RBAC for Chains annotation check..."
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/challenge4/tekton-patched/rbac/
	@echo "Applying build pipeline with release gate (notify-release in finally)..."
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/challenge4/tekton-patched/tasks/
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/challenge4/tekton-patched/pipelines/
	@echo "Applying secured release pipeline resources..."
	@kubectl --context kind-$(CLUSTER_NAME) apply -f challenges/challenge4/tekton-patched/triggers/
	@echo "✓ Secured release pipeline deployed:"
	@echo "  Build:   push-build-pipeline-with-release-gate (finally waits for Chains)"
	@echo "  Release: release-pipeline-secure (verify-image-policy → copy-image → create-pr)"

trigger-release-pipeline-secure: ## Manually trigger the secured release pipeline
	@kubectl --context kind-$(CLUSTER_NAME) create -f challenges/challenge4/tekton-patched/manual-release-pipelinerun-secure.yaml
	@echo "✓ Secured release pipeline triggered. Monitor: kubectl get pipelineruns -n release-pipeline -w"

trigger-build-with-release-gate: ## Trigger Challenge 4 build pipeline (finally block + Chains check + auto-release)
	@echo "Triggering build pipeline with release gate..."
	@kubectl --context kind-$(CLUSTER_NAME) create -f challenges/challenge4/tekton-patched/manual-build-pipelinerun-with-release-gate.yaml
	@echo "✓ Build pipeline triggered. The finally block will auto-trigger the release pipeline after Chains signs."
	@echo "Monitor build:   tkn pr logs -f -n ci --last"
	@echo "Monitor release: kubectl get pipelineruns -n release-pipeline -w"

setup-e2e-scenario: setup-production-cluster setup-production-registry setup-gateway-production setup-production-gitea push-recipe-api-to-production setup-argocd seed-production-repo ## Complete Challenge 4 setup
	@echo ""
	@echo "Applying ArgoCD application..."
	@kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) apply -f challenges/e2e-scenario/argocd/recipe-api-application.yaml
	@echo ""
	@echo "Waiting for ArgoCD to sync application..."
	@sleep 5
	@echo ""
	@echo "========================================"
	@echo "E2E Scenario Setup Complete"
	@echo "========================================"
	@echo ""
	@echo "✓ Production KinD cluster created: $(PRODUCTION_CLUSTER_NAME)"
	@echo "✓ Production Gitea installed (http://gitea-prod.sc.local:31080)"
	@echo "✓ recipe-api image loaded into production cluster"
	@echo "✓ ArgoCD installed in namespace: $(ARGOCD_NAMESPACE)"
	@echo "✓ production-manifests repository seeded"
	@echo "✓ ArgoCD application deployed (recipe-api-production)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Verify setup: make verify-e2e-scenario"
	@echo "  2. Check ArgoCD sync status: kubectl --context kind-$(PRODUCTION_CLUSTER_NAME) get applications -n argocd"
	@echo "  3. Run the E2E demo: challenges/e2e-scenario/e2e-demo.sh"
	@echo ""

verify-e2e-scenario: ## Verify E2E scenario setup
	@echo "Verifying E2E scenario setup..."
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

clean-e2e-scenario: ## Cleanup E2E scenario (delete production cluster)
	@echo "Cleaning up E2E scenario..."
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
