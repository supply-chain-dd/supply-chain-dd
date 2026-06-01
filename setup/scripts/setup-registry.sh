#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"
source "${SCRIPT_DIR}/cert-utils.sh"

CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-registry}"

# Registry credentials
REGISTRY_USER="${REGISTRY_USER:-sc-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-RegistryPass123!}"

# Persistent TLS certificate storage
CERTS_OUTPUT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/certs"
mkdir -p "${CERTS_OUTPUT_DIR}"
CERT_FILE="${CERTS_OUTPUT_DIR}/registry.crt"
KEY_FILE="${CERTS_OUTPUT_DIR}/registry.key"

CERT_REGENERATED=false

echo "Setting up Docker registry in KinD cluster: ${CLUSTER_NAME}"

# Check if kubectl is working
if ! kubectl cluster-info &> /dev/null; then
    echo "Error: kubectl is not configured or cluster is not running."
    echo "Run 'make setup-kind' first."
    exit 1
fi

# Create registry namespace
echo "Creating registry namespace..."
kubectl create namespace "${REGISTRY_NAMESPACE}" 2>/dev/null || echo "  Namespace '${REGISTRY_NAMESPACE}' already exists"

# Generate self-signed TLS certificate only when needed
if cert_is_valid "${CERT_FILE}" "${KEY_FILE}" && cert_sans_match "${CERT_FILE}" "${REGISTRY_DOMAIN}"; then
    echo "✓ Existing TLS certificate is valid and matches domain, reusing it."
else
    echo "Generating self-signed TLS certificate..."

    TMPCNF=$(mktemp)
    trap "rm -f ${TMPCNF}" EXIT

    cat > "${TMPCNF}" <<EOF
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
O = Supply Chain Registry
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
DNS.6 = ${REGISTRY_DOMAIN}
IP.1 = 127.0.0.1
EOF

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "${KEY_FILE}" \
      -out "${CERT_FILE}" \
      -config "${TMPCNF}" \
      -extensions req_ext 2>/dev/null

    rm -f "${TMPCNF}"
    trap - EXIT

    if [ ! -f "${CERT_FILE}" ]; then
        echo "Error: Failed to generate TLS certificate"
        exit 1
    fi

    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}"

    CERT_REGENERATED=true
    echo "✓ TLS certificate generated"
    echo "  Certificate saved to: ${CERT_FILE}"
fi

# Create or update TLS secret only when needed
if [ "${CERT_REGENERATED}" = "true" ]; then
    echo "Updating TLS secret with new certificate..."
    kubectl create secret tls registry-tls \
      --cert="${CERT_FILE}" \
      --key="${KEY_FILE}" \
      -n "${REGISTRY_NAMESPACE}" \
      --dry-run=client -o yaml | kubectl apply -f -
elif ! kubectl get secret registry-tls -n "${REGISTRY_NAMESPACE}" &>/dev/null; then
    echo "Creating TLS secret..."
    kubectl create secret tls registry-tls \
      --cert="${CERT_FILE}" \
      --key="${KEY_FILE}" \
      -n "${REGISTRY_NAMESPACE}" \
      --dry-run=client -o yaml | kubectl apply -f -
    CERT_REGENERATED=true
else
    echo "✓ TLS secret already exists, no update needed."
fi

# Generate htpasswd for basic auth
echo "Generating registry credentials..."
# Try multiple methods to generate htpasswd
if command -v htpasswd &> /dev/null; then
    # Use htpasswd if available
    HTPASSWD=$(htpasswd -Bbn "${REGISTRY_USER}" "${REGISTRY_PASS}")
else
    # Use container runtime (default to podman if not set)
    CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman}

    if command -v "${CONTAINER_RUNTIME}" &> /dev/null; then
        HTPASSWD=$(${CONTAINER_RUNTIME} run --rm --entrypoint htpasswd docker.io/httpd:2 -Bbn "${REGISTRY_USER}" "${REGISTRY_PASS}")
    else
        echo "Error: htpasswd or ${CONTAINER_RUNTIME} is required to generate credentials."
        echo "Please install one of: apache2-utils (for htpasswd) or set CONTAINER_RUNTIME to your preferred runtime"
        exit 1
    fi
fi

# Create Secret with registry credentials
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

# Create PersistentVolumeClaim for registry storage
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

# Create ConfigMap for registry configuration
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

# Create Deployment for registry
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

# Create Service for internal and external access
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
  type: ClusterIP
  selector:
    app: registry
  ports:
  - name: registry
    port: 5000
    targetPort: 5000
    protocol: TCP
EOF

# Create ConfigMap in kube-public for discoverability
echo "Creating registry discovery ConfigMap..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "https://${REGISTRY_HOST}"
    hostFromContainerRuntime: "https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
    hostFromClusterNetwork: "https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# Restart the deployment only if the certificate changed
if [ "${CERT_REGENERATED}" = "true" ]; then
    echo "Certificate changed — restarting registry deployment..."
    kubectl rollout restart deployment/registry -n "${REGISTRY_NAMESPACE}"
fi

echo "Waiting for registry to be ready..."
kubectl rollout status deployment/registry -n "${REGISTRY_NAMESPACE}" --timeout=120s
kubectl wait --for=condition=ready --timeout=120s pod -l app=registry -n "${REGISTRY_NAMESPACE}"

# Propagate CA certificate to downstream namespaces only if cert changed
if [ "${CERT_REGENERATED}" = "true" ]; then
    for ns in ci tekton-chains; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            echo "Updating registry-ca-cert ConfigMap in ${ns}..."
            kubectl create configmap registry-ca-cert \
              --from-file=ca.crt="${CERT_FILE}" \
              -n "${ns}" \
              --dry-run=client -o yaml | kubectl apply -f -
        fi
    done
    if kubectl get namespace release-pipeline &>/dev/null; then
        echo "Updating ci-registry-ca-cert ConfigMap in release-pipeline..."
        kubectl create configmap ci-registry-ca-cert \
          --from-file=ca.crt="${CERT_FILE}" \
          -n release-pipeline \
          --dry-run=client -o yaml | kubectl apply -f -
    fi
fi

# Restart controllers that cache the CA certificate only if cert changed
if [ "${CERT_REGENERATED}" = "true" ]; then
    if kubectl get deployment tekton-chains-controller -n tekton-chains &>/dev/null; then
        echo "Restarting Tekton Chains controller to pick up new certificate..."
        kubectl rollout restart deployment/tekton-chains-controller -n tekton-chains
        kubectl rollout status deployment/tekton-chains-controller -n tekton-chains --timeout=60s
    fi
fi

# Create Gateway TLSRoute if Gateway exists
if kubectl get gateway sc-local -n envoy-gateway-system &>/dev/null; then
    echo "Creating Gateway TLSRoute for registry..."
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: TLSRoute
metadata:
  name: registry
  namespace: ${REGISTRY_NAMESPACE}
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
    echo "  ✓ Registry Gateway route created"
fi

echo ""
echo "✓ Registry setup complete!"
echo ""
echo "Registry Access Information:"
echo "============================"
echo "External (via Gateway):   https://${REGISTRY_HOST}"
echo "Internal (from cluster):  https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
echo ""
echo "Registry Credentials:"
echo "===================="
echo "Username: ${REGISTRY_USER}"
echo "Password: ${REGISTRY_PASS}"
echo ""
echo "TLS Certificate:"
echo "================"
echo "Location: ${CERT_FILE}"
echo ""
echo "⚠  Configure TLS trust before using the registry:"
echo "  make configure-registry-tls"
echo ""
echo "Test registry access:"
echo "====================="
echo "  podman login ${REGISTRY_HOST} -u ${REGISTRY_USER} -p ${REGISTRY_PASS}"
echo "  podman tag nginx:latest ${REGISTRY_HOST}/nginx:test"
echo "  podman push ${REGISTRY_HOST}/nginx:test"
echo ""
echo "  curl --cacert ${CERT_FILE} -u ${REGISTRY_USER}:${REGISTRY_PASS} https://${REGISTRY_HOST}/v2/_catalog"
echo ""
