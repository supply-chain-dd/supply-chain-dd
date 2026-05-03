#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ctf-cluster}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-registry}"
REGISTRY_NODE_PORT="${REGISTRY_NODE_PORT:-30000}"

# Registry credentials
REGISTRY_USER="${REGISTRY_USER:-ctf-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-CTFRegistryPass123!}"

# TLS configuration
CERT_DIR="$(mktemp -d)"
trap "rm -rf ${CERT_DIR}" EXIT

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

# Generate self-signed TLS certificate
echo "Generating self-signed TLS certificate..."

# Create OpenSSL config for Subject Alternative Names
cat > "${CERT_DIR}/openssl.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = US
ST = CTF
L = CTF
O = CTF Registry
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
IP.1 = 127.0.0.1
EOF

# Generate private key and certificate
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

# Save certificate to local directory for client configuration
CERTS_OUTPUT_DIR="${PWD}/certs"
mkdir -p "${CERTS_OUTPUT_DIR}"
cp "${CERT_DIR}/tls.crt" "${CERTS_OUTPUT_DIR}/registry.crt"
echo "  Certificate saved to: ${CERTS_OUTPUT_DIR}/registry.crt"

# Create TLS secret
echo "Creating TLS secret..."
kubectl create secret tls registry-tls \
  --cert="${CERT_DIR}/tls.crt" \
  --key="${CERT_DIR}/tls.key" \
  -n "${REGISTRY_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

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
  type: NodePort
  selector:
    app: registry
  ports:
  - name: registry
    port: 5000
    targetPort: 5000
    nodePort: ${REGISTRY_NODE_PORT}
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
    host: "https://localhost:${REGISTRY_NODE_PORT}"
    hostFromContainerRuntime: "https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
    hostFromClusterNetwork: "https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# Wait for registry to be ready
echo "Waiting for registry to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/registry -n "${REGISTRY_NAMESPACE}"
kubectl wait --for=condition=ready --timeout=120s pod -l app=registry -n "${REGISTRY_NAMESPACE}"

echo ""
echo "✓ Registry setup complete!"
echo ""
echo "Registry Access Information:"
echo "============================"
echo "External (from host):     https://localhost:${REGISTRY_NODE_PORT}"
echo "Internal (from cluster):  https://registry.${REGISTRY_NAMESPACE}.svc.cluster.local:5000"
echo "Internal (short):         https://registry.${REGISTRY_NAMESPACE}:5000"
echo ""
echo "Registry Credentials:"
echo "===================="
echo "Username: ${REGISTRY_USER}"
echo "Password: ${REGISTRY_PASS}"
echo ""
echo "TLS Certificate:"
echo "================"
echo "Location: ${CERTS_OUTPUT_DIR}/registry.crt"
echo ""
echo "⚠️  IMPORTANT: Configure TLS trust before using the registry!"
echo ""
echo "For Podman (recommended):"
echo "-------------------------"
echo "  # Create certificates directory"
echo "  sudo mkdir -p /etc/containers/certs.d/localhost:${REGISTRY_NODE_PORT}"
echo "  sudo cp ${CERTS_OUTPUT_DIR}/registry.crt /etc/containers/certs.d/localhost:${REGISTRY_NODE_PORT}/ca.crt"
echo ""
echo "  # Alternative: System-wide trust (Fedora/RHEL)"
echo "  sudo cp ${CERTS_OUTPUT_DIR}/registry.crt /etc/pki/ca-trust/source/anchors/registry.crt"
echo "  sudo update-ca-trust"
echo ""
echo "For Docker:"
echo "-----------"
echo "  # Create certificates directory"
echo "  sudo mkdir -p /etc/docker/certs.d/localhost:${REGISTRY_NODE_PORT}"
echo "  sudo cp ${CERTS_OUTPUT_DIR}/registry.crt /etc/docker/certs.d/localhost:${REGISTRY_NODE_PORT}/ca.crt"
echo "  sudo systemctl restart docker"
echo ""
echo "  # Alternative: Insecure registry (NOT RECOMMENDED)"
echo "  # Add to /etc/docker/daemon.json:"
echo "  # {\"insecure-registries\": [\"localhost:${REGISTRY_NODE_PORT}\"]}"
echo ""
echo "Test registry access:"
echo "====================="
echo "  # After configuring TLS, test with your container runtime:"
echo "  # Using Podman:"
echo "  podman login localhost:${REGISTRY_NODE_PORT} -u ${REGISTRY_USER} -p ${REGISTRY_PASS}"
echo "  podman tag nginx:latest localhost:${REGISTRY_NODE_PORT}/nginx:test"
echo "  podman push localhost:${REGISTRY_NODE_PORT}/nginx:test"
echo ""
echo "  # Using Docker:"
echo "  docker login localhost:${REGISTRY_NODE_PORT} -u ${REGISTRY_USER} -p ${REGISTRY_PASS}"
echo "  docker tag nginx:latest localhost:${REGISTRY_NODE_PORT}/nginx:test"
echo "  docker push localhost:${REGISTRY_NODE_PORT}/nginx:test"
echo ""
echo "  # List images in registry:"
echo "  curl --cacert ${CERTS_OUTPUT_DIR}/registry.crt -u ${REGISTRY_USER}:${REGISTRY_PASS} https://localhost:${REGISTRY_NODE_PORT}/v2/_catalog"
echo ""
echo "  # Or bypass TLS verification (testing only):"
echo "  curl -k -u ${REGISTRY_USER}:${REGISTRY_PASS} https://localhost:${REGISTRY_NODE_PORT}/v2/_catalog"
echo ""
