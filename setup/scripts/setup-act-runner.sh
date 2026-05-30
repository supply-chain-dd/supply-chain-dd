#!/usr/bin/env bash
set -euo pipefail

GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="sc-admin"
GITEA_ADMIN_PASSWORD="SecurePass123!"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-30002}"
ACT_RUNNER_VERSION="${ACT_RUNNER_VERSION:-0.2.11}"

echo "Setting up Gitea Actions Runner..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

# Check if Gitea is running
if ! kubectl get pods -n "${GITEA_NAMESPACE}" | grep -q "gitea"; then
    echo "Error: Gitea is not installed. Run 'make setup-gitea' first."
    exit 1
fi

echo "Waiting for Gitea to be fully ready..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=gitea -n "${GITEA_NAMESPACE}" --timeout=300s

# Get Gitea service endpoint
GITEA_SERVICE="gitea-http.${GITEA_NAMESPACE}.svc.cluster.local:3000"

echo "Creating runner registration token..."

# Create a job to register the runner and get the token
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: gitea-runner-token-${RANDOM}
  namespace: ${GITEA_NAMESPACE}
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: token-generator
        image: curlimages/curl:latest
        command:
        - sh
        - -c
        - |
          # Wait for Gitea to be ready
          until curl -sf http://${GITEA_SERVICE}/ > /dev/null 2>&1; do
            echo "Waiting for Gitea to be ready..."
            sleep 5
          done

          # Create the supply-chain-dd repository
          echo "Creating supply-chain-dd repository..."
          curl -X POST "http://${GITEA_SERVICE}/api/v1/user/repos" \
            -u '${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}' \
            -H "Content-Type: application/json" \
            -d '{"name":"supply-chain-dd","description":"Supply Chain Security Deep Dive Repository","private":false,"auto_init":true}' \
            2>/dev/null || echo "Repository may already exist, continuing..."

          # Wait a moment for repository to be fully created
          sleep 2

          # Create runner registration token for the repository
          TOKEN=\$(curl -X POST "http://${GITEA_SERVICE}/api/v1/repos/${GITEA_ADMIN_USER}/supply-chain-dd/actions/runners/registration-token" \
            -u '${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}' \
            -H "Content-Type: application/json" 2>/dev/null | grep -o '"token":"[^"]*' | cut -d'"' -f4)

          if [ -z "\$TOKEN" ]; then
            echo "ERROR: Failed to create runner registration token"
            exit 1
          fi

          echo "SUCCESS: Registration token created"
          echo "TOKEN:\$TOKEN"
EOF

# Wait for the token generation job to complete
echo "Waiting for token generation to complete..."
JOB_NAME=$(kubectl get jobs -n "${GITEA_NAMESPACE}" -o name | grep gitea-runner-token | head -1)
kubectl wait --for=condition=complete "${JOB_NAME}" -n "${GITEA_NAMESPACE}" --timeout=120s

# Extract token from job logs
echo "Extracting registration token..."
POD_NAME=$(kubectl get pods -n "${GITEA_NAMESPACE}" -l batch.kubernetes.io/job-name --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
REGISTRATION_TOKEN=$(kubectl logs -n "${GITEA_NAMESPACE}" "${POD_NAME}" | grep "TOKEN:" | cut -d: -f2)

if [ -z "${REGISTRATION_TOKEN}" ]; then
  echo "Error: Failed to extract registration token from job logs"
  kubectl logs -n "${GITEA_NAMESPACE}" "${POD_NAME}"
  exit 1
fi

echo "Creating secret with registration token..."
kubectl create secret generic gitea-runner-token \
  --from-literal=token="${REGISTRATION_TOKEN}" \
  --namespace="${GITEA_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Token stored in secret gitea-runner-token"

# Create RBAC for runner to create pods
echo "Creating RBAC permissions..."

cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: act-runner
  namespace: ${GITEA_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: act-runner
  namespace: ${GITEA_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/exec"]
  verbs: ["get", "list", "create", "delete", "watch"]
- apiGroups: [""]
  resources: ["secrets", "configmaps"]
  verbs: ["get", "list", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: act-runner
  namespace: ${GITEA_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: act-runner
subjects:
- kind: ServiceAccount
  name: act-runner
  namespace: ${GITEA_NAMESPACE}
EOF

# Deploy act_runner with Kubernetes executor
echo "Deploying act_runner with Kubernetes executor..."

cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: act-runner-config
  namespace: ${GITEA_NAMESPACE}
data:
  config.yaml: |
    log:
      level: info
    runner:
      file: .runner
      capacity: 2
      timeout: 3h
      insecure: false
      fetch_timeout: 5s
      fetch_interval: 2s
    cache:
      enabled: true
    # Use Kubernetes executor instead of Docker
    container:
      network: host
      privileged: false
      force_pull: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: act-runner
  namespace: ${GITEA_NAMESPACE}
  labels:
    app: act-runner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: act-runner
  template:
    metadata:
      labels:
        app: act-runner
    spec:
      serviceAccountName: act-runner
      containers:
      - name: runner
        image: gitea/act_runner:${ACT_RUNNER_VERSION}
        imagePullPolicy: IfNotPresent
        env:
        - name: GITEA_INSTANCE_URL
          value: "http://${GITEA_SERVICE}"
        - name: GITEA_RUNNER_REGISTRATION_TOKEN
          valueFrom:
            secretKeyRef:
              name: gitea-runner-token
              key: token
        - name: GITEA_RUNNER_NAME
          value: "sc-k8s-runner"
        - name: GITEA_RUNNER_LABELS
          value: "ubuntu-latest,ubuntu-22.04,ubuntu-20.04"
        - name: CONFIG_FILE
          value: "/etc/act_runner/config.yaml"
        command:
        - sh
        - -c
        - |
          # Wait for Gitea to be ready
          until wget -q --spider http://${GITEA_SERVICE}/ 2>/dev/null; do
            echo "Waiting for Gitea..."
            sleep 5
          done

          # Register runner if not already registered
          if [ ! -f /data/.runner ]; then
            echo "Registering runner..."
            act_runner register --no-interactive \
              --instance "\$GITEA_INSTANCE_URL" \
              --token "\$GITEA_RUNNER_REGISTRATION_TOKEN" \
              --name "\$GITEA_RUNNER_NAME" \
              --labels "\$GITEA_RUNNER_LABELS" \
              --config "\$CONFIG_FILE"
          fi

          # Start the runner with Kubernetes executor
          echo "Starting runner daemon..."
          export KUBERNETES_NAMESPACE=${GITEA_NAMESPACE}
          act_runner daemon --config "\$CONFIG_FILE"
        volumeMounts:
        - name: runner-data
          mountPath: /data
        - name: config
          mountPath: /etc/act_runner
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: runner-data
        emptyDir: {}
      - name: config
        configMap:
          name: act-runner-config
EOF

echo "Waiting for act_runner to be ready..."
kubectl wait --for=condition=Available deployment/act-runner -n "${GITEA_NAMESPACE}" --timeout=300s

echo "✓ act_runner deployed successfully"
echo ""
echo "Runner Information:"
echo "  Status: kubectl get pods -n ${GITEA_NAMESPACE} -l app=act-runner"
echo "  Logs:   kubectl logs -n ${GITEA_NAMESPACE} -l app=act-runner -f"
echo ""
echo "You can now use Gitea Actions in your repositories!"
echo "Create a .gitea/workflows/test.yaml file in your repos to define workflows."
echo ""
