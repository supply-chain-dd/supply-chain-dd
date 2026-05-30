# Local Docker Registry Setup

This project includes a local Docker registry (registry:3) deployed within the Kubernetes cluster to support the deep dive environment.

## Overview

The registry is deployed as a Kubernetes Deployment in its own namespace with:
- **TLS/HTTPS**: Self-signed certificate for encrypted communication
- **Authentication**: Basic auth with username/password
- **Storage**: Persistent volume for image storage
- **Access**: Available both internally (from pods) and externally (from host)
- **Integration**: Registry credentials stored in registry-credentials secret

## Setup

### Quick Start

```bash
# Setup the registry
make setup-registry

# Configure TLS trust (automated - recommended)
make configure-registry-tls

# Or manually configure (choose one):
# For Podman:
sudo mkdir -p /etc/containers/certs.d/registry.sc.local:30443
sudo cp certs/registry.crt /etc/containers/certs.d/registry.sc.local:30443/ca.crt

# For Docker:
sudo mkdir -p /etc/docker/certs.d/registry.sc.local:30443
sudo cp certs/registry.crt /etc/docker/certs.d/registry.sc.local:30443/ca.crt
sudo systemctl restart docker

# Verify it's working
make verify-registry

# Login and test
podman login registry.sc.local:30443 -u sc-admin -p RegistryPass123!
podman tag nginx:latest registry.sc.local:30443/nginx:test
podman push registry.sc.local:30443/nginx:test
```

### Manual Deployment

If you prefer to deploy manually:

```bash
cd setup
./scripts/setup-registry.sh
```

## Architecture

### Components

1. **Namespace**: `registry`
2. **Deployment**: `registry` (1 replica)
3. **Service**: `registry` (NodePort: 30000)
4. **PersistentVolumeClaim**: `registry-storage` (10Gi)
5. **Secret**: `registry-auth` (htpasswd + credentials)
6. **Secret**: `registry-tls` (TLS certificate and key)
7. **ConfigMap**: `registry-config` (registry configuration)
8. **Local File**: `certs/registry.crt` (CA certificate for client configuration)

### Access Points

| Location | URL | Port |
|----------|-----|------|
| External (host) | `https://registry.sc.local:30443` | 30000 (NodePort) |
| Internal (cluster) | `https://registry.registry.svc.cluster.local:5000` | 5000 |
| Internal (short) | `https://registry.registry:5000` | 5000 |

## TLS Configuration

The registry is configured with a self-signed TLS certificate for HTTPS communication.

### Certificate Details

- **Location**: `certs/registry.crt` (generated during setup)
- **Type**: Self-signed X.509 certificate
- **Validity**: 365 days
- **Subject Alternative Names**:
  - DNS: localhost, registry, registry.registry, registry.registry.svc, registry.registry.svc.cluster.local
  - IP: 127.0.0.1

### Configuring TLS Trust

Before using the registry, you must configure your container runtime to trust the self-signed certificate.

#### Automated Configuration (Recommended)

Use the provided helper script for interactive configuration:

```bash
# Run the interactive configuration helper
make configure-registry-tls

# Or directly:
./setup/scripts/configure-registry-tls.sh
```

This script will:
1. Detect your container runtime (Podman or Docker)
2. Offer configuration options (per-registry or system-wide)
3. Install the certificate in the appropriate location
4. Restart services if needed

#### Manual Configuration

If you prefer manual configuration:

##### For Podman (Recommended)

**Option 1: Per-registry configuration (Recommended)**
```bash
# Create certificates directory for registry.sc.local:30443
sudo mkdir -p /etc/containers/certs.d/registry.sc.local:30443
sudo cp certs/registry.crt /etc/containers/certs.d/registry.sc.local:30443/ca.crt
```

**Option 2: System-wide trust (Fedora/RHEL/CentOS)**
```bash
# Add to system CA trust store
sudo cp certs/registry.crt /etc/pki/ca-trust/source/anchors/registry.crt
sudo update-ca-trust
```

**Option 3: System-wide trust (Debian/Ubuntu)**
```bash
# Add to system CA trust store
sudo cp certs/registry.crt /usr/local/share/ca-certificates/registry.crt
sudo update-ca-certificates
```

#### For Docker

**Option 1: Per-registry configuration (Recommended)**
```bash
# Create certificates directory for registry.sc.local:30443
sudo mkdir -p /etc/docker/certs.d/registry.sc.local:30443
sudo cp certs/registry.crt /etc/docker/certs.d/registry.sc.local:30443/ca.crt
sudo systemctl restart docker
```

**Option 2: Insecure registry (NOT RECOMMENDED for production)**
```bash
# Edit /etc/docker/daemon.json
sudo tee /etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["registry.sc.local:30443"]
}
EOF
sudo systemctl restart docker
```

## Authentication

Default credentials (can be customized via environment variables):
- **Username**: `sc-admin`
- **Password**: `RegistryPass123!`

### Custom Credentials

Set environment variables before running setup:

```bash
REGISTRY_USER=myuser REGISTRY_PASS=mypass make setup-registry
```

## Usage Examples

### From Host Machine

⚠️ **Important**: You must configure TLS trust (see [TLS Configuration](#tls-configuration)) before using the registry.

#### Using Podman

```bash
# After configuring TLS trust, login
podman login registry.sc.local:30443 -u sc-admin -p RegistryPass123!

# Tag an image
podman tag nginx:latest registry.sc.local:30443/nginx:test

# Push to registry
podman push registry.sc.local:30443/nginx:test

# Pull from registry
podman pull registry.sc.local:30443/nginx:test

# List images in registry (with certificate)
curl --cacert certs/registry.crt -u sc-admin:RegistryPass123! https://registry.sc.local:30443/v2/_catalog

# Or bypass TLS verification (testing only)
curl -k -u sc-admin:RegistryPass123! https://registry.sc.local:30443/v2/_catalog
```

#### Using Docker

```bash
# After configuring TLS trust, login
docker login registry.sc.local:30443 -u sc-admin -p RegistryPass123!

# Tag and push
docker tag nginx:latest registry.sc.local:30443/nginx:test
docker push registry.sc.local:30443/nginx:test

# Pull from registry
docker pull registry.sc.local:30443/nginx:test
```

### From Within Cluster

Pods within the cluster can access the registry via HTTPS. Since the certificate is self-signed, you'll need to either:
1. Use the `-k` flag with curl to skip verification
2. Mount the CA certificate and configure the client to use it

#### Using kubectl run

```bash
# Test registry access (skipping TLS verification)
kubectl run test-registry --image=curlimages/curl:latest --rm -it --restart=Never -- \
  sh -c 'curl -k -u sc-admin:RegistryPass123! https://registry.registry.svc.cluster.local:5000/v2/_catalog'
```

#### Using the CA certificate in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: registry-client
spec:
  containers:
  - name: client
    image: curlimages/curl:latest
    command: ["/bin/sh", "-c"]
    args:
    - |
      curl --cacert /certs/ca.crt \
        -u sc-admin:RegistryPass123! \
        https://registry.registry.svc.cluster.local:5000/v2/_catalog
    volumeMounts:
    - name: registry-ca
      mountPath: /certs
      readOnly: true
  volumes:
  - name: registry-ca
    secret:
      secretName: registry-tls
      items:
      - key: tls.crt
        path: ca.crt
```

#### In Pod Spec

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  containers:
  - name: my-container
    image: registry.registry.svc.cluster.local:5000/my-image:latest
  imagePullSecrets:
  - name: registry-pull-secret
```

#### Create ImagePullSecret

For pulling images that require authentication:

```bash
kubectl create secret docker-registry registry-pull-secret \
  --docker-server=registry.registry.svc.cluster.local:5000 \
  --docker-username=sc-admin \
  --docker-password=RegistryPass123! \
  -n your-namespace
```

**Note**: For HTTPS with self-signed certificates, you may need to configure the container runtime's certificate trust within the nodes. In kind clusters, the pods will typically skip certificate verification or you can mount the CA certificate as shown above.

### In Tekton Pipelines

The registry credentials are automatically available in the `registry-credentials` secret in the `ci` namespace:

```yaml
apiVersion: tekton.dev/v1beta1
kind: TaskRun
metadata:
  name: push-to-registry
spec:
  taskSpec:
    steps:
    - name: push-image
      image: gcr.io/go-containerregistry/crane:latest
      env:
      - name: REGISTRY_URL
        valueFrom:
          secretKeyRef:
            name: registry-credentials
            key: registry-url
      - name: REGISTRY_USER
        valueFrom:
          secretKeyRef:
            name: registry-credentials
            key: registry-user
      - name: REGISTRY_PASS
        valueFrom:
          secretKeyRef:
            name: registry-credentials
            key: registry-password
      script: |
        echo "${REGISTRY_PASS}" | crane auth login "${REGISTRY_URL}" -u "${REGISTRY_USER}" --password-stdin
        crane push my-image.tar "${REGISTRY_URL}/my-image:latest"
```

## Management

### Check Status

```bash
# View all registry resources
kubectl get all -n registry

# View registry logs
kubectl logs -n registry -l app=registry -f

# Check storage usage
kubectl describe pvc registry-storage -n registry
```

### List Images

```bash
# Using curl with CA certificate
curl --cacert certs/registry.crt -u sc-admin:RegistryPass123! https://registry.sc.local:30443/v2/_catalog

# Or skip certificate verification (testing only)
curl -k -u sc-admin:RegistryPass123! https://registry.sc.local:30443/v2/_catalog

# Get tags for a specific image
curl -k -u sc-admin:RegistryPass123! https://registry.sc.local:30443/v2/nginx/tags/list
```

### Delete an Image

```bash
# First, get the digest
curl -k -v -u sc-admin:RegistryPass123! \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  https://registry.sc.local:30443/v2/nginx/manifests/test 2>&1 | grep Docker-Content-Digest

# Then delete using the digest
curl -k -u sc-admin:RegistryPass123! \
  -X DELETE https://registry.sc.local:30443/v2/nginx/manifests/sha256:DIGEST_HERE
```

### Restart Registry

```bash
kubectl rollout restart deployment registry -n registry
kubectl rollout status deployment registry -n registry
```

## Troubleshooting

### Registry Pod Not Starting

```bash
# Check pod status
kubectl get pods -n registry

# View pod logs
kubectl logs -n registry -l app=registry

# Describe pod for events
kubectl describe pod -n registry -l app=registry
```

### Cannot Push/Pull Images

**First, check TLS configuration:**
```bash
# Verify certificate exists
ls -l certs/registry.crt

# Check if certificate is configured (Podman)
ls -l /etc/containers/certs.d/registry.sc.local:30443/ca.crt

# Check if certificate is configured (Docker)
ls -l /etc/docker/certs.d/registry.sc.local:30443/ca.crt
```

**Then verify service accessibility:**
```bash
# Verify service is accessible
kubectl get svc registry -n registry

# Test from within cluster (skip cert verification)
kubectl run test-registry --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -k -v https://registry.registry.svc.cluster.local:5000/v2/

# Test from host (skip cert verification)
curl -k -v https://registry.sc.local:30443/v2/

# Test with certificate
curl --cacert certs/registry.crt -v https://registry.sc.local:30443/v2/
```

**Common TLS errors:**
- `SSL certificate problem`: Certificate not trusted → Configure TLS trust
- `certificate signed by unknown authority`: Same as above
- `x509: certificate is valid for localhost, not X`: You're using the wrong hostname

### Authentication Failures

```bash
# Check secret exists
kubectl get secret registry-auth -n registry

# Verify credentials
kubectl get secret registry-auth -n registry -o jsonpath='{.data.username}' | base64 -d
kubectl get secret registry-auth -n registry -o jsonpath='{.data.password}' | base64 -d

# Test authentication (skip TLS verification for testing)
curl -k -u sc-admin:RegistryPass123! https://registry.sc.local:30443/v2/_catalog
```

### Storage Issues

```bash
# Check PVC status
kubectl get pvc registry-storage -n registry

# Check available space
kubectl exec -n registry deployment/registry -- df -h /var/lib/registry

# View storage events
kubectl describe pvc registry-storage -n registry
```

## Configuration

### Environment Variables

The following environment variables can be set when running `make setup-registry`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | `ci-cluster` | Name of the kind cluster |
| `REGISTRY_NAMESPACE` | `registry` | Kubernetes namespace for registry |
| `REGISTRY_NODE_PORT` | `30000` | NodePort for external access |
| `REGISTRY_USER` | `sc-admin` | Registry username |
| `REGISTRY_PASS` | `RegistryPass123!` | Registry password |

### Registry Configuration

The registry is configured via ConfigMap `registry-config` in the `registry` namespace. To modify:

```bash
# Edit the configuration
kubectl edit configmap registry-config -n registry

# Restart registry to apply changes
kubectl rollout restart deployment registry -n registry
```

Key configuration options:
- **Storage**: Filesystem-based with deletion enabled
- **Authentication**: htpasswd-based basic auth
- **Health checks**: Storage driver health checks enabled
- **Headers**: Security headers configured

## Cleanup

### Remove Registry Only

```bash
kubectl delete namespace registry
```

### Full Cleanup

The registry will be automatically removed when you run:

```bash
make clean
```

## Security Considerations

1. **Self-Signed Certificate**: This setup uses a self-signed certificate suitable for development/deep dive environments. For production, use certificates from a trusted CA.
2. **Default Credentials**: Change default credentials in production environments
3. **Network Policies**: Consider adding network policies to restrict access
4. **Certificate Management**: The TLS certificate is valid for 365 days. Regenerate before expiration.
5. **Storage**: PersistentVolume data persists after pod deletion
6. **RBAC**: Registry service account has minimal permissions
7. **Certificate Storage**: The `certs/` directory contains the CA certificate - keep it secure if used in production

## Integration with Deep Dive Challenges

The registry credentials are automatically included in the `registry-credentials` secret when you run:

```bash
make setup-ci-pr-pipeline
# or
make setup-ci-pr-pipeline-secure
```

The secret contains:
- `flag`: The registry credentials
- `registry-url`: Registry URL for internal cluster access
- `registry-user`: Registry username
- `registry-password`: Registry password

This allows deep dive challenges to interact with the registry for scenarios involving container image manipulation.

## References

- [Docker Registry Documentation](https://docs.docker.com/registry/)
- [Registry Configuration Reference](https://docs.docker.com/registry/configuration/)
- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [kind Local Registry Documentation](https://kind.sigs.k8s.io/docs/user/local-registry/)
