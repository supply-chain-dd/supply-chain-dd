#!/usr/bin/env bash
set -euo pipefail

SIGSTORE_SCAFFOLD_VERSION="${SIGSTORE_SCAFFOLD_VERSION:-v0.7.24}"
KNATIVE_VERSION="${KNATIVE_VERSION:-1.18.0}"
REKOR_NODE_PORT="${REKOR_NODE_PORT:-30006}"
TUF_NODE_PORT="${TUF_NODE_PORT:-30007}"
FULCIO_NODE_PORT="${FULCIO_NODE_PORT:-30008}"

echo "============================================"
echo "Deploying local Sigstore stack (scaffolding)"
echo "  Scaffolding: ${SIGSTORE_SCAFFOLD_VERSION}"
echo "  Knative:     v${KNATIVE_VERSION}"
echo "============================================"
echo ""

create_nodeport_service() {
    local NAME=$1 NAMESPACE=$2 NODE_PORT=$3
    cat <<EOSVC | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    serving.knative.dev/service: ${NAME}
  ports:
  - port: 8080
    targetPort: 8080
    nodePort: ${NODE_PORT}
    protocol: TCP
EOSVC
}

# ============================================================
# Prerequisites check
# ============================================================

for cmd in kubectl openssl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ ${cmd} not found. Please install it first."
        exit 1
    fi
done

# ============================================================
# Step 0a: Allow anonymous access to OIDC discovery endpoints
# ============================================================
# Fulcio needs to fetch /.well-known/openid-configuration and /openid/v1/jwks
# from the API server to validate ServiceAccount tokens. Without this, it gets
# 403 Forbidden because the Fulcio pod runs with automountServiceAccountToken: false.

if ! kubectl get clusterrolebinding oidc-reviewer &>/dev/null; then
    echo "Creating OIDC discovery ClusterRoleBinding..."
    kubectl create clusterrolebinding oidc-reviewer \
        --clusterrole=system:service-account-issuer-discovery \
        --group=system:unauthenticated
    echo "  ✓ OIDC discovery accessible"
else
    echo "✓ OIDC discovery ClusterRoleBinding already exists"
fi
echo ""

# ============================================================
# Step 0b: Clean up old Helm-based installation (if present)
# ============================================================

if command -v helm &>/dev/null && helm status scaffold -n sigstore-system &>/dev/null 2>&1; then
    echo "Removing old Helm-based sigstore installation..."
    helm uninstall scaffold -n sigstore-system
    kubectl delete namespace sigstore-system --ignore-not-found=true
    for ns in fulcio-system rekor-system ctlog-system trillian-system tuf-system tsa-system; do
        kubectl delete namespace "$ns" --ignore-not-found=true 2>/dev/null || true
    done
    echo "  ✓ Old Helm installation removed"
    echo ""
fi

# ============================================================
# Step 1: Install Knative Serving + Kourier (if not present)
# ============================================================

KNATIVE_BASE="https://github.com/knative/serving/releases/download/knative-v${KNATIVE_VERSION}"
KOURIER_BASE="https://github.com/knative/net-kourier/releases/download/knative-v${KNATIVE_VERSION}"

if kubectl get namespace knative-serving &>/dev/null 2>&1; then
    echo "✓ Knative Serving already installed"
else
    echo "Installing Knative Serving v${KNATIVE_VERSION}..."

    echo "  Applying Serving CRDs..."
    kubectl apply -f "${KNATIVE_BASE}/serving-crds.yaml"
    sleep 10

    echo "  Applying Serving Core..."
    kubectl apply -f "${KNATIVE_BASE}/serving-core.yaml"

    echo "  Waiting for Knative Serving deployments..."
    for deploy in $(kubectl get deploy --namespace knative-serving -oname 2>/dev/null); do
        kubectl rollout status --timeout 5m --namespace knative-serving "$deploy"
    done

    echo "  ✓ Knative Serving installed"
fi

if kubectl get namespace kourier-system &>/dev/null 2>&1; then
    echo "✓ Kourier already installed"
else
    echo "Installing Kourier (Knative networking)..."
    kubectl apply -f "${KOURIER_BASE}/kourier.yaml"

    echo "  Waiting for Kourier deployments..."
    for deploy in $(kubectl get deploy --namespace kourier-system -oname 2>/dev/null); do
        kubectl rollout status --timeout 5m --namespace kourier-system "$deploy"
    done

    echo "  ✓ Kourier installed"
fi

echo "Configuring Knative networking..."
kubectl patch configmap/config-network \
    --namespace knative-serving \
    --type merge \
    --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'

kubectl patch configmap/config-features \
    --namespace knative-serving \
    --type merge \
    --patch '{"data":{"kubernetes.podspec-fieldref":"enabled","kubernetes.podspec-volumes-emptydir":"enabled","kubernetes.podspec-persistent-volume-claim":"enabled","kubernetes.podspec-persistent-volume-write":"enabled"}}'

kubectl patch configmap/config-autoscaler \
    --namespace knative-serving \
    --type merge \
    --patch '{"data":{"min-scale":"1","max-scale":"1"}}'

echo "  ✓ Knative networking configured"

echo "Setting up default domain..."
kubectl apply -f "${KNATIVE_BASE}/serving-default-domain.yaml" 2>/dev/null || true
sleep 3
kubectl wait -n knative-serving --timeout=180s --for=condition=Complete jobs --all 2>/dev/null || true

echo ""

# ============================================================
# Step 2: Check if sigstore is already fully deployed
# ============================================================

if kubectl get ksvc tuf -n tuf-system &>/dev/null 2>&1; then
    TUF_READY=$(kubectl get ksvc tuf -n tuf-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$TUF_READY" = "True" ]; then
        echo "✓ Sigstore scaffolding already fully deployed (including TUF)"
        echo ""

        # Ensure TUF root ConfigMap exists in ctf-challenge
        if ! kubectl get configmap sigstore-tuf-root -n ctf-challenge &>/dev/null; then
            echo "Creating TUF root ConfigMap in ctf-challenge..."
            kubectl -n tuf-system get secrets tuf-root -ojsonpath='{.data.root}' | base64 -d > /tmp/tuf-root.json
            kubectl create namespace ctf-challenge 2>/dev/null || true
            kubectl create configmap sigstore-tuf-root -n ctf-challenge --from-file=root.json=/tmp/tuf-root.json
            rm -f /tmp/tuf-root.json
            echo "  ✓ sigstore-tuf-root ConfigMap created"
        fi

        # Print endpoints
        REKOR_URL=$(kubectl -n rekor-system get ksvc rekor -ojsonpath='{.status.url}' 2>/dev/null || echo "unknown")
        FULCIO_URL=$(kubectl -n fulcio-system get ksvc fulcio -ojsonpath='{.status.url}' 2>/dev/null || echo "unknown")
        TUF_MIRROR=$(kubectl -n tuf-system get ksvc tuf -ojsonpath='{.status.url}' 2>/dev/null || echo "unknown")
        # Ensure NodePort services exist
        create_nodeport_service rekor rekor-system "${REKOR_NODE_PORT}"
        create_nodeport_service tuf tuf-system "${TUF_NODE_PORT}"
        create_nodeport_service fulcio fulcio-system "${FULCIO_NODE_PORT}"

        echo ""
        echo "Service endpoints (internal):"
        echo "  Fulcio: ${FULCIO_URL}"
        echo "  Rekor:  ${REKOR_URL}"
        echo "  TUF:    ${TUF_MIRROR}"
        echo ""
        echo "Host access (NodePort):"
        echo "  Rekor:  http://localhost:${REKOR_NODE_PORT}"
        echo "  TUF:    http://localhost:${TUF_NODE_PORT}"
        echo "  Fulcio: http://localhost:${FULCIO_NODE_PORT}"
        exit 0
    fi
fi

# ============================================================
# Step 3: Deploy sigstore scaffolding from release
# ============================================================

echo "Installing sigstore scaffolding ${SIGSTORE_SCAFFOLD_VERSION}..."
echo ""

RELEASE_BASE="https://github.com/sigstore/scaffolding/releases/download/${SIGSTORE_SCAFFOLD_VERSION}"

# --- 3a. Trillian ---
echo "[1/6] Installing Trillian..."
if curl -s -i "${RELEASE_BASE}/release-trillian.yaml" | head -1 | grep -q '404'; then
    echo "  Trillian release not found (may be bundled), skipping..."
else
    kubectl apply -f "${RELEASE_BASE}/release-trillian.yaml"
    echo "  Waiting for Trillian..."
    kubectl wait --timeout 5m -n trillian-system --for=condition=Ready ksvc log-server 2>/dev/null || true
    kubectl wait --timeout 5m -n trillian-system --for=condition=Ready ksvc log-signer 2>/dev/null || true
fi

# --- 3b. Rekor ---
echo "[2/6] Installing Rekor..."
REKOR_PASS=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
REKOR_DIR=$(mktemp -d)
openssl genpkey -algorithm ed25519 -out "${REKOR_DIR}/key.pem" -pass "pass:${REKOR_PASS}"
openssl pkey -in "${REKOR_DIR}/key.pem" -out "${REKOR_DIR}/pub.pem" -pubout

kubectl apply -f "${RELEASE_BASE}/release-rekor.yaml"
curl -Ls "${RELEASE_BASE}/release-rekor.yaml" | \
    sed -e "s/<private-placeholder>/$(base64 -w0 < "${REKOR_DIR}/key.pem")/" \
        -e "s/<public-placeholder>/$(base64 -w0 < "${REKOR_DIR}/pub.pem")/" \
        -e "s/<password-placeholder>/$(echo -n "${REKOR_PASS}" | base64 -w0)/" | \
    kubectl apply -f -
rm -f "${REKOR_DIR}/key.pem" "${REKOR_DIR}/pub.pem"
rmdir "${REKOR_DIR}"

echo "  Waiting for Rekor..."
kubectl wait --timeout 5m -n rekor-system --for=condition=Complete jobs --all
kubectl wait --timeout 5m -n rekor-system --for=condition=Ready ksvc rekor
create_nodeport_service rekor rekor-system "${REKOR_NODE_PORT}"
echo "  ✓ Rekor accessible at http://localhost:${REKOR_NODE_PORT}"

# --- 3c. Fulcio ---
echo "[3/6] Installing Fulcio..."
FULCIO_PASS=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
FULCIO_DIR=$(mktemp -d)
openssl ecparam -name prime256v1 -genkey | openssl pkcs8 -passout "pass:${FULCIO_PASS}" -topk8 -out "${FULCIO_DIR}/key.pem"
openssl req -x509 -new -key "${FULCIO_DIR}/key.pem" -out "${FULCIO_DIR}/cert.pem" \
    -sha256 -days 365 -subj "/O=ctf/CN=fulcio.scaffolding.ctf" -passin "pass:${FULCIO_PASS}"

FULCIO_YAML=$(mktemp --tmpdir fulcioXXX)
curl -Ls -o "${FULCIO_YAML}" "${RELEASE_BASE}/release-fulcio.yaml"
sed -i -e "s/<private-placeholder>/$(base64 -w0 < "${FULCIO_DIR}/key.pem")/" \
       -e "s/<cert-placeholder>/$(base64 -w0 < "${FULCIO_DIR}/cert.pem")/" \
       -e "s/<password-placeholder>/$(echo -n "${FULCIO_PASS}" | base64 -w0)/" "${FULCIO_YAML}"
kubectl apply -f "${FULCIO_YAML}"
rm -f "${FULCIO_YAML}"

echo "  Waiting for Fulcio..."
kubectl -n fulcio-system get job 2>&1 | grep -q 'No resources found' || \
    kubectl wait --timeout 5m -n fulcio-system --for=condition=Complete jobs --all
kubectl wait --timeout 5m -n fulcio-system --for=condition=Ready ksvc fulcio
kubectl wait --timeout 5m -n fulcio-system --for=condition=Ready ksvc fulcio-grpc 2>/dev/null || true
create_nodeport_service fulcio fulcio-system "${FULCIO_NODE_PORT}"
echo "  ✓ Fulcio accessible at http://localhost:${FULCIO_NODE_PORT}"

# --- 3d. CTLog ---
echo "[4/6] Installing CT Log..."
CTLOG_DIR=$(mktemp -d)
openssl ecparam -name prime256v1 -genkey -noout -out "${CTLOG_DIR}/key.pem"
openssl ec -in "${CTLOG_DIR}/key.pem" -pubout -out "${CTLOG_DIR}/pub.pem"

curl -Ls "${RELEASE_BASE}/release-ctlog.yaml" | \
    sed -e "s/<private-placeholder>/$(base64 -w0 < "${CTLOG_DIR}/key.pem")/" \
        -e "s/<public-placeholder>/$(base64 -w0 < "${CTLOG_DIR}/pub.pem")/" \
        -e "s/<cert-placeholder>/$(base64 -w0 < "${FULCIO_DIR}/cert.pem")/" | \
    kubectl apply -f -
rm -f "${CTLOG_DIR}/key.pem" "${CTLOG_DIR}/pub.pem"
rmdir "${CTLOG_DIR}"

echo "  Waiting for CT Log..."
kubectl wait --timeout 5m -n ctlog-system --for=condition=Complete jobs --all
kubectl wait --timeout 2m -n ctlog-system --for=condition=Ready ksvc ctlog

# Clean up Fulcio key material now that CTLog has the cert
rm -f "${FULCIO_DIR}/key.pem" "${FULCIO_DIR}/cert.pem"
rmdir "${FULCIO_DIR}"

# --- 3e. TSA ---
echo "[5/6] Installing TSA..."
kubectl apply -f "${RELEASE_BASE}/release-tsa.yaml" 2>/dev/null || true
kubectl wait --timeout 5m -n tsa-system --for=condition=Complete jobs --all 2>/dev/null || true
kubectl wait --timeout 2m -n tsa-system --for=condition=Ready ksvc tsa 2>/dev/null || true

# --- 3f. TUF ---
echo "[6/6] Installing TUF..."
kubectl apply -f "${RELEASE_BASE}/release-tuf.yaml"

# Copy public keys from component namespaces into tuf-system
kubectl -n ctlog-system get secrets ctlog-public-key -oyaml | \
    sed -e '/creationTimestamp:/d' -e '/uid:/d' -e '/resourceVersion:/d' -e 's/namespace: .*/namespace: tuf-system/' | \
    kubectl apply -f -
kubectl -n fulcio-system get secrets fulcio-pub-key -oyaml | \
    sed -e '/creationTimestamp:/d' -e '/uid:/d' -e '/resourceVersion:/d' -e 's/namespace: .*/namespace: tuf-system/' | \
    kubectl apply -f -
kubectl -n rekor-system get secrets rekor-pub-key -oyaml | \
    sed -e '/creationTimestamp:/d' -e '/uid:/d' -e '/resourceVersion:/d' -e 's/namespace: .*/namespace: tuf-system/' | \
    kubectl apply -f -
kubectl -n tsa-system get secrets tsa-cert-chain -oyaml | \
    sed -e '/creationTimestamp:/d' -e '/uid:/d' -e '/resourceVersion:/d' -e 's/namespace: .*/namespace: tuf-system/' | \
    kubectl apply -f - 2>/dev/null || true

echo "  Waiting for TUF..."
kubectl wait --timeout 4m -n tuf-system --for=condition=Complete jobs --all
kubectl wait --timeout 2m -n tuf-system --for=condition=Ready ksvc tuf
create_nodeport_service tuf tuf-system "${TUF_NODE_PORT}"
echo "  ✓ TUF accessible at http://localhost:${TUF_NODE_PORT}"

echo ""
echo "✓ Sigstore stack deployed successfully"

# ============================================================
# Step 4: Extract TUF root and create ConfigMap
# ============================================================

echo ""
echo "Extracting TUF root..."
kubectl -n tuf-system get secrets tuf-root -ojsonpath='{.data.root}' | base64 -d > /tmp/tuf-root.json

kubectl create namespace ctf-challenge 2>/dev/null || true
kubectl create configmap sigstore-tuf-root -n ctf-challenge \
    --from-file=root.json=/tmp/tuf-root.json \
    --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/tuf-root.json
echo "  ✓ sigstore-tuf-root ConfigMap created in ctf-challenge"

# ============================================================
# Step 5: Print endpoints
# ============================================================

REKOR_URL=$(kubectl -n rekor-system get ksvc rekor -ojsonpath='{.status.url}')
FULCIO_URL=$(kubectl -n fulcio-system get ksvc fulcio -ojsonpath='{.status.url}')
FULCIO_GRPC_URL=$(kubectl -n fulcio-system get ksvc fulcio-grpc -ojsonpath='{.status.url}' 2>/dev/null || echo "N/A")
TUF_MIRROR=$(kubectl -n tuf-system get ksvc tuf -ojsonpath='{.status.url}')

echo ""
echo "✓ Local Sigstore stack setup complete"
echo ""
echo "Service endpoints (internal / Knative):"
echo "  Fulcio:      ${FULCIO_URL}"
echo "  Fulcio gRPC: ${FULCIO_GRPC_URL}"
echo "  Rekor:       ${REKOR_URL}"
echo "  TUF:         ${TUF_MIRROR}"
echo ""
echo "Host access (NodePort):"
echo "  Rekor:  http://localhost:${REKOR_NODE_PORT}"
echo "  TUF:    http://localhost:${TUF_NODE_PORT}"
echo "  Fulcio: http://localhost:${FULCIO_NODE_PORT}"
echo ""
echo "OIDC issuer (for keyless verification):"
echo "  kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer'"
echo ""
echo "Next steps:"
echo "  1. Deploy keyless signing pipeline: make setup-challenge2-tekton-keyless"
echo "  2. Trigger keyless build:           make trigger-challenge2-build-keyless"
echo "  3. Verify keyless signature:        see challenges/challenge2/keyless-signing-demo.sh"
echo ""
