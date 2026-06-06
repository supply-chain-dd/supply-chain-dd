#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CERT_FILE="${1:-${SETUP_DIR}/certs/registry.crt}"

echo "Registry TLS Configuration Helper"
echo "=================================="
echo ""

# Check if certificate exists
if [ ! -f "${CERT_FILE}" ]; then
    echo "Error: Certificate file not found: ${CERT_FILE}"
    echo "Run 'make setup-registry' first to generate the certificate."
    exit 1
fi

echo "Certificate found: ${CERT_FILE}"
echo "Target registry:   ${REGISTRY_HOST}"
echo ""

# Validate that the certificate's SANs match the target registry domain
CERT_SANS=$(openssl x509 -in "${CERT_FILE}" -noout -text 2>/dev/null \
    | grep -A1 "Subject Alternative Name" \
    | tail -1 \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//' \
    | grep "^DNS:" \
    | sed 's/DNS://')

if ! echo "${CERT_SANS}" | grep -qw "${REGISTRY_DOMAIN}"; then
    echo "ERROR: Certificate SAN mismatch!"
    echo ""
    echo "  Target registry domain: ${REGISTRY_DOMAIN}"
    echo "  Certificate SANs:       $(echo ${CERT_SANS} | tr '\n' ', ')"
    echo ""
    echo "  The certificate does not cover '${REGISTRY_DOMAIN}'."
    echo "  Installing it would break TLS for ${REGISTRY_HOST}."
    echo ""
    echo "  Possible fixes:"
    echo "    - Use the correct certificate file for this registry"
    echo "    - Re-run 'make setup-registry' to regenerate the certificate"
    exit 1
fi
echo "✓ Certificate SANs match target domain '${REGISTRY_DOMAIN}'"
echo ""

# Detect container runtime (respect CONTAINER_RUNTIME env var if set)
RUNTIME="${CONTAINER_RUNTIME:-}"

if [ -z "$RUNTIME" ]; then
    # Auto-detect if not set
    if command -v podman &> /dev/null; then
        RUNTIME="podman"
        echo "✓ Podman detected"
    elif command -v docker &> /dev/null; then
        RUNTIME="docker"
        echo "✓ Docker detected"
    else
        echo "Error: Neither podman nor docker found."
        exit 1
    fi
else
    # Validate the specified runtime
    if ! command -v "$RUNTIME" &> /dev/null; then
        echo "Error: CONTAINER_RUNTIME is set to '$RUNTIME' but it's not installed."
        exit 1
    fi
    echo "✓ Using CONTAINER_RUNTIME=$RUNTIME"
fi

echo "Configuring per-registry certificate trust..."

CONTAINERS_CERT_DIR="/etc/containers/certs.d/${REGISTRY_HOST}"
echo "  Creating directory: ${CONTAINERS_CERT_DIR}"
sudo mkdir -p "${CONTAINERS_CERT_DIR}"
echo "  Copying certificate..."
sudo cp "${CERT_FILE}" "${CONTAINERS_CERT_DIR}/ca.crt"
sudo chmod 644 "${CONTAINERS_CERT_DIR}/ca.crt"
echo "  -> Podman/Buildah configured"

DOCKER_CERT_DIR="/etc/docker/certs.d/${REGISTRY_HOST}"
echo "  Creating directory: ${DOCKER_CERT_DIR}"
sudo mkdir -p "${DOCKER_CERT_DIR}"
echo "  Copying certificate..."
sudo cp "${CERT_FILE}" "${DOCKER_CERT_DIR}/ca.crt"
sudo chmod 644 "${DOCKER_CERT_DIR}/ca.crt"
echo "  -> Docker/crane/oras configured"

if [ "$RUNTIME" = "docker" ]; then
    echo "  Restarting Docker..."
    sudo systemctl restart docker
fi

echo ""
echo "Certificate installed in both /etc/containers and /etc/docker cert directories."

# Verify the cert file matches what the live server is actually serving.
# The registry pod caches its cert at startup; if the K8s secret was updated
# after the pod started, the pod serves a stale cert.
echo ""
echo "Verifying certificate matches the live registry..."
LIVE_FP=$(openssl s_client -connect "${REGISTRY_HOST}" -servername "${REGISTRY_DOMAIN}" </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)
FILE_FP=$(openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)

REGISTRY_KUBECTL_CONTEXT="${REGISTRY_KUBECTL_CONTEXT:-}"
KUBECTL_CTX=( ${REGISTRY_KUBECTL_CONTEXT:+--context "${REGISTRY_KUBECTL_CONTEXT}"} )

if [ -n "${LIVE_FP}" ] && [ "${LIVE_FP}" != "${FILE_FP}" ]; then
    echo "  Certificate mismatch detected!"
    echo "    File:   ${FILE_FP}"
    echo "    Server: ${LIVE_FP}"
    echo "  Restarting registry pod to load the current certificate..."
    kubectl "${KUBECTL_CTX[@]}" rollout restart deployment/registry -n registry 2>/dev/null
    kubectl "${KUBECTL_CTX[@]}" rollout status deployment/registry -n registry --timeout=60s 2>/dev/null
    echo "✓ Registry pod restarted — certificate is now in sync"
else
    echo "✓ Certificate matches live server"
fi

echo ""
echo "Test the configuration:"
echo "  ${RUNTIME} login ${REGISTRY_HOST} -u sc-admin -p RegistryPass123!"
echo "  ${RUNTIME} pull nginx:latest"
echo "  ${RUNTIME} tag nginx:latest ${REGISTRY_HOST}/nginx:test"
echo "  ${RUNTIME} push ${REGISTRY_HOST}/nginx:test"
echo ""
