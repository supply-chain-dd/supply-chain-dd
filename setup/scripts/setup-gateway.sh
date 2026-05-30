#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.8.0}"
CLUSTER_TYPE="${1:-ci}" # "ci" or "production"

# ============================================================
# Route creation functions (must be defined before use)
# ============================================================

create_ci_routes() {
    # Core routes (namespaces exist at setup time)
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gitea
  namespace: gitea
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: http
  hostnames:
  - "${GITEA_DOMAIN}"
  rules:
  - backendRefs:
    - name: gitea-http
      port: 3000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: http
  hostnames:
  - "${DASHBOARD_DOMAIN}"
  rules:
  - backendRefs:
    - name: tekton-dashboard
      port: 9097
EOF

    # Registry route (may not exist yet if setup-registry hasn't run)
    if kubectl get namespace registry &>/dev/null; then
        kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: registry
  namespace: registry
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: registry-passthrough
  hostnames:
  - "${REGISTRY_DOMAIN}"
  rules:
  - backendRefs:
    - name: registry
      port: 5000
EOF
    else
        echo "  ⚠ Registry namespace not found — registry route will be created by setup-registry"
    fi

    # Sigstore routes (created later by setup-sigstore-local)
    local sigstore_created=false
    for ns_svc in "rekor-system:rekor:${REKOR_DOMAIN}" "tuf-system:tuf:${TUF_DOMAIN}" "fulcio-system:fulcio:${FULCIO_DOMAIN}"; do
        IFS=: read -r ns svc domain <<< "${ns_svc}"
        if kubectl get namespace "${ns}" &>/dev/null; then
            kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${svc}
  namespace: ${ns}
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: http
  hostnames:
  - "${domain}"
  rules:
  - backendRefs:
    - name: ${svc}-nodeport
      port: 8080
EOF
            sigstore_created=true
        fi
    done
    if [ "${sigstore_created}" = "false" ]; then
        echo "  ⚠ Sigstore namespaces not found — routes will be created by setup-sigstore-local"
    fi
}

create_production_routes() {
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: argocd-passthrough
  hostnames:
  - "${ARGOCD_DOMAIN}"
  rules:
  - backendRefs:
    - name: argocd-server
      port: 443
EOF

    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gitea-prod
  namespace: gitea
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: http
  hostnames:
  - "${GITEA_PROD_DOMAIN}"
  rules:
  - backendRefs:
    - name: gitea-http
      port: 3000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: recipe-api
  namespace: default
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: http
  hostnames:
  - "${APP_DOMAIN}"
  rules:
  - backendRefs:
    - name: recipe-api
      port: 8080
EOF

    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: registry-prod
  namespace: registry
spec:
  parentRefs:
  - name: sc-local
    namespace: envoy-gateway-system
    sectionName: registry-prod-passthrough
  hostnames:
  - "${REGISTRY_PROD_DOMAIN}"
  rules:
  - backendRefs:
    - name: registry
      port: 5000
EOF
}

# ============================================================
# Main script
# ============================================================

echo "Setting up Gateway API with Envoy Gateway ${ENVOY_GATEWAY_VERSION} (${CLUSTER_TYPE} cluster)..."

# ============================================================
# Step 1: Install Envoy Gateway (includes Gateway API CRDs)
# ============================================================

if helm status eg -n envoy-gateway-system &>/dev/null 2>&1; then
    echo "✓ Envoy Gateway already installed"
else
    echo "Installing Envoy Gateway..."
    helm install eg oci://docker.io/envoyproxy/gateway-helm \
        --version "${ENVOY_GATEWAY_VERSION}" \
        -n envoy-gateway-system \
        --create-namespace

    echo "Waiting for Envoy Gateway controller..."
    kubectl wait --timeout=5m -n envoy-gateway-system \
        deployment/envoy-gateway --for=condition=Available
    echo "✓ Envoy Gateway installed"
fi

# ============================================================
# Step 2: Create GatewayClass and EnvoyProxy for NodePort
# ============================================================

echo ""
echo "Creating GatewayClass and EnvoyProxy..."

kubectl apply -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: nodeport-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: nodeport-proxy
    namespace: envoy-gateway-system
EOF

echo "Waiting for GatewayClass to be accepted..."
for i in $(seq 1 15); do
    STATUS=$(kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
    if [ "${STATUS}" = "True" ]; then
        echo "✓ GatewayClass accepted"
        break
    fi
    sleep 2
done

# ============================================================
# Step 3: Create Gateway resource
# ============================================================

echo ""
echo "Creating Gateway resource..."

if [ "${CLUSTER_TYPE}" = "ci" ]; then
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: sc-local
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: ${GATEWAY_HTTP_PORT}
    allowedRoutes:
      namespaces:
        from: All
  - name: registry-passthrough
    protocol: TLS
    port: ${GATEWAY_HTTPS_PORT}
    hostname: "${REGISTRY_DOMAIN}"
    tls:
      mode: Passthrough
    allowedRoutes:
      namespaces:
        from: All
EOF
elif [ "${CLUSTER_TYPE}" = "production" ]; then
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: sc-local
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: ${GATEWAY_PROD_HTTP_PORT}
    allowedRoutes:
      namespaces:
        from: All
  - name: argocd-passthrough
    protocol: TLS
    port: ${GATEWAY_PROD_HTTPS_PORT}
    hostname: "${ARGOCD_DOMAIN}"
    tls:
      mode: Passthrough
    allowedRoutes:
      namespaces:
        from: All
  - name: registry-prod-passthrough
    protocol: TLS
    port: ${GATEWAY_PROD_HTTPS_PORT}
    hostname: "${REGISTRY_PROD_DOMAIN}"
    tls:
      mode: Passthrough
    allowedRoutes:
      namespaces:
        from: All
EOF
fi

# ============================================================
# Step 4: Wait for Gateway to be programmed and patch NodePorts
# ============================================================

echo ""
echo "Waiting for Gateway to be accepted..."
kubectl wait --timeout=120s -n envoy-gateway-system \
    gateway/sc-local --for=condition=Accepted 2>/dev/null || true

echo "Waiting for Envoy proxy Service..."
SVC_NAME=""
for i in $(seq 1 30); do
    SVC_NAME=$(kubectl get svc -n envoy-gateway-system \
        -l gateway.envoyproxy.io/owning-gateway-name=sc-local \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${SVC_NAME}" ]; then
        break
    fi
    sleep 2
done

if [ -z "${SVC_NAME}" ]; then
    echo "Error: Envoy proxy Service not found after 60s"
    echo ""
    echo "Debug:"
    kubectl get gateway -n envoy-gateway-system -o wide 2>/dev/null || true
    kubectl get pods -n envoy-gateway-system 2>/dev/null || true
    kubectl get events -n envoy-gateway-system --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
    exit 1
fi

if [ "${CLUSTER_TYPE}" = "ci" ]; then
    HTTP_PORT=${GATEWAY_HTTP_PORT}
    HTTPS_PORT=${GATEWAY_HTTPS_PORT}
else
    HTTP_PORT=${GATEWAY_PROD_HTTP_PORT}
    HTTPS_PORT=${GATEWAY_PROD_HTTPS_PORT}
fi

echo "Patching Service ${SVC_NAME} with NodePort ${HTTP_PORT}/${HTTPS_PORT}..."
kubectl patch svc "${SVC_NAME}" -n envoy-gateway-system --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/spec/ports/0/nodePort\", \"value\": ${HTTP_PORT}},
  {\"op\": \"replace\", \"path\": \"/spec/ports/1/nodePort\", \"value\": ${HTTPS_PORT}}
]" 2>/dev/null || echo "  NodePort patch may need manual adjustment if port indices differ"

echo "✓ Gateway ready"

# ============================================================
# Step 5: Create routes
# ============================================================

echo ""
echo "Creating routes..."

if [ "${CLUSTER_TYPE}" = "ci" ]; then
    create_ci_routes
elif [ "${CLUSTER_TYPE}" = "production" ]; then
    create_production_routes
fi

echo ""
echo "✓ Gateway API setup complete for ${CLUSTER_TYPE} cluster"
echo ""

if [ "${CLUSTER_TYPE}" = "ci" ]; then
    echo "Service URLs:"
    echo "  Gitea:      http://${GITEA_HOST}"
    echo "  Registry:   https://${REGISTRY_HOST}"
    echo "  Dashboard:  http://${DASHBOARD_HOST}"
    echo "  Rekor:      http://${REKOR_HOST}"
    echo "  Fulcio:     http://${FULCIO_HOST}"
    echo "  TUF:        http://${TUF_HOST}"
    echo "  Gitea SSH:  ssh://git@${GITEA_DOMAIN}:${GITEA_SSH_PORT}"
else
    echo "Service URLs:"
    echo "  ArgoCD:          https://${ARGOCD_HOST}"
    echo "  Gitea (prod):    http://${GITEA_PROD_HOST}"
    echo "  Registry (prod): https://${REGISTRY_PROD_HOST}"
    echo "  Recipe API:      http://${APP_HOST}"
    echo "  Gitea SSH:       ssh://git@${GITEA_PROD_DOMAIN}:${GITEA_PROD_SSH_PORT}"
fi
