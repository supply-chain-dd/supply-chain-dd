#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-production-cluster}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-registry}"

REGISTRY_USER="${REGISTRY_USER:-sc-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-RegistryPass123!}"

CERT_DIR="$(mktemp -d)"
trap "rm -rf ${CERT_DIR}" EXIT

echo "==> Setting up Docker registry on production cluster: ${CLUSTER_NAME}"

# Verify we're on the right cluster
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER_NAME" ]]; then
    echo "Error: Not on production cluster context."
    echo "Current context: $CURRENT_CONTEXT"
    echo "Expected: kind-$CLUSTER_NAME"
    echo ""
    echo "Switch context with: kubectl config use-context kind-$CLUSTER_NAME"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "Error: kubectl is not configured or cluster is not running."
    exit 1
fi

# Create registry namespace
echo "Creating registry namespace..."
kubectl create namespace "${REGISTRY_NAMESPACE}" 2>/dev/null || echo "  Namespace '${REGISTRY_NAMESPACE}' already exists"

# Generate self-signed TLS certificate
echo "Generating self-signed TLS certificate..."

cat > "${CERT_DIR}/openssl.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = US
ST = SC
L = SC
O = Supply Chain Production Registry
OU = Security
CN = localhost

[req_ext]
basicConstraints = critical,CA:TRUE
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = registry
DNS.3 = registry.${REGISTRY_NAMESPACE}
DNS.4 = registry.${REGISTRY_NAMESPACE}.svc
DNS.5 = registry.${REGISTRY_NAMESPACE}.svc.cluster.local
DNS.6 = ${REGISTRY_PROD_HOST}
DNS.7 = production-cluster-control-plane.dns.podman
IP.1 = 127.0.0.1
EOF

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${CERT_DIR}/tls.key" \
  -out "${CERT_DIR}/tls.crt" \
  -config "${CERT_DIR}/openssl.cnf" \
  -extensions req_ext 2>/dev/null

if [ ! -f "${CERT_DIR}/tls.crt" ]; then
    echo "Error: Failed to generate TLS certificate"
    exit 1
fi

echo "✓ TLS certificate generated"

CERTS_OUTPUT_DIR="${PWD}/certs"
mkdir -p "${CERTS_OUTPUT_DIR}"
cp "${CERT_DIR}/tls.crt" "${CERTS_OUTPUT_DIR}/production-registry.crt"
echo "  Certificate saved to: ${CERTS_OUTPUT_DIR}/production-registry.crt"

# Create TLS secret
echo "Creating TLS secret..."
kubectl create secret tls registry-tls \
  --cert="${CERT_DIR}/tls.crt" \
  --key="${CERT_DIR}/tls.key" \
  -n "${REGISTRY_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Generate htpasswd for basic auth
echo "Generating registry credentials..."
if command -v htpasswd &> /dev/null; then
    HTPASSWD=$(htpasswd -Bbn "${REGISTRY_USER}" "${REGISTRY_PASS}")
else
    CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman}
    if command -v "${CONTAINER_RUNTIME}" &> /dev/null; then
        HTPASSWD=$(${CONTAINER_RUNTIME} run --rm --entrypoint htpasswd docker.io/httpd:2 -Bbn "${REGISTRY_USER}" "${REGISTRY_PASS}")
    else
        echo "Error: htpasswd or ${CONTAINER_RUNTIME} is required to generate credentials."
        exit 1
    fi
fi

echo "Creating registry authentication secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: registry-auth
  namespace: ${REGISTRY_NAMESPACE}
type: Opaque
stringData:
  htpasswd: |
$(echo "${HTPASSWD}" | sed 's/^/    /')
  username: "${REGISTRY_USER}"
  password: "${REGISTRY_PASS}"
EOF

echo "Creating PersistentVolumeClaim for registry storage..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-storage
  namespace: ${REGISTRY_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

echo "Creating registry configuration..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-config
  namespace: ${REGISTRY_NAMESPACE}
data:
  config.yml: |
    version: 0.1
    log:
      fields:
        service: registry
    storage:
      cache:
        blobdescriptor: inmemory
      filesystem:
        rootdirectory: /var/lib/registry
      delete:
        enabled: true
    http:
      addr: :5000
      headers:
        X-Content-Type-Options: [nosniff]
      tls:
        certificate: /certs/tls.crt
        key: /certs/tls.key
    auth:
      htpasswd:
        realm: Registry Realm
        path: /auth/htpasswd
    health:
      storagedriver:
        enabled: true
        interval: 10s
        threshold: 3
EOF

echo "Creating registry deployment..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: ${REGISTRY_NAMESPACE}
  labels:
    app: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:3
        ports:
        - containerPort: 5000
          name: registry
          protocol: TCP
        volumeMounts:
        - name: storage
          mountPath: /var/lib/registry
        - name: auth
          mountPath: /auth
          readOnly: true
        - name: config
          mountPath: /etc/docker/registry
          readOnly: true
        - name: certs
          mountPath: /certs
          readOnly: true
        env:
        - name: REGISTRY_HTTP_TLS_CERTIFICATE
          value: "/certs/tls.crt"
        - name: REGISTRY_HTTP_TLS_KEY
          value: "/certs/tls.key"
        - name: REGISTRY_HTTP_ADDR
          value: ":5000"
        - name: REGISTRY_HTTPS_ADDR
          value: ":5000"
        - name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY
          value: "/var/lib/registry"
        livenessProbe:
          httpGet:
            path: /
            port: 5000
            scheme: HTTPS
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 5000
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: registry-storage
      - name: auth
        secret:
          secretName: registry-auth
          items:
          - key: htpasswd
            path: htpasswd
      - name: config
        configMap:
          name: registry-config
      - name: certs
        secret:
          secretName: registry-tls
EOF

echo "Creating registry service..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: ${REGISTRY_NAMESPACE}
  labels:
    app: registry
spec:
  type: NodePort
  selector:
    app: registry
  ports:
  - name: registry
    port: 5000
    targetPort: 5000
    nodePort: 30082
    protocol: TCP
EOF

echo "Creating registry discovery ConfigMap..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "https://${REGISTRY_PROD_HOST}"
    hostFromContainerRuntime: "https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
    hostFromClusterNetwork: "https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# Wait for registry to be ready
echo "Waiting for registry to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/registry -n "${REGISTRY_NAMESPACE}"
kubectl wait --for=condition=ready --timeout=120s pod -l app=registry -n "${REGISTRY_NAMESPACE}"

# Create production namespace and imagePullSecret
echo "Creating production namespace and imagePullSecret..."
kubectl create namespace production 2>/dev/null || echo "  Namespace 'production' already exists"
kubectl create secret docker-registry production-registry-auth \
  --docker-server=${REGISTRY_PROD_HOST} \
  --docker-username="${REGISTRY_USER}" \
  --docker-password="${REGISTRY_PASS}" \
  -n production \
  --dry-run=client -o yaml | kubectl apply -f -

# Create Gateway TLSRoute for production registry
if kubectl get gateway sc-local -n envoy-gateway-system &>/dev/null; then
    echo "Creating Gateway TLSRoute for production registry..."
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: TLSRoute
metadata:
  name: registry-prod
  namespace: ${REGISTRY_NAMESPACE}
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
    echo "  ✓ Registry Gateway route created"
fi

echo ""
echo "✓ Production registry setup complete!"
echo ""
echo "Registry Access Information:"
echo "============================"
echo "External (via Gateway):   https://${REGISTRY_PROD_HOST}"
echo "Internal (from cluster):  https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
echo ""
echo "Registry Credentials:"
echo "===================="
echo "Username: ${REGISTRY_USER}"
echo "Password: ${REGISTRY_PASS}"
echo ""
echo "TLS Certificate:"
echo "================"
echo "Location: ${CERTS_OUTPUT_DIR}/production-registry.crt"
echo ""
