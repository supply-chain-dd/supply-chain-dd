#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/domains.sh"

CERT_FILE="${1:-certs/registry.crt}"

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

echo ""
echo "Choose configuration method:"
echo "  1) Per-registry configuration (Recommended)"
echo "  2) System-wide CA trust"
echo "  3) Show manual instructions and exit"
echo ""
read -p "Enter choice [1-3]: " choice

case $choice in
    1)
        echo ""
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
        ;;
    2)
        echo ""
        echo "Configuring system-wide CA trust..."

        # Detect OS
        if [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
            # Fedora/RHEL/CentOS
            echo "  Detected RHEL-based system"
            echo "  Copying certificate to /etc/pki/ca-trust/source/anchors/..."
            sudo cp "${CERT_FILE}" /etc/pki/ca-trust/source/anchors/registry.crt
            echo "  Updating CA trust..."
            sudo update-ca-trust
            echo ""
            echo "✓ System CA trust updated (RHEL/Fedora/CentOS)"
        elif [ -f /etc/debian_version ]; then
            # Debian/Ubuntu
            echo "  Detected Debian-based system"
            echo "  Copying certificate to /usr/local/share/ca-certificates/..."
            sudo cp "${CERT_FILE}" /usr/local/share/ca-certificates/registry.crt
            echo "  Updating CA certificates..."
            sudo update-ca-certificates
            echo ""
            echo "✓ System CA trust updated (Debian/Ubuntu)"
        else
            echo "  Warning: OS not detected. Manual configuration required."
            echo ""
            echo "For RHEL/Fedora/CentOS:"
            echo "  sudo cp ${CERT_FILE} /etc/pki/ca-trust/source/anchors/registry.crt"
            echo "  sudo update-ca-trust"
            echo ""
            echo "For Debian/Ubuntu:"
            echo "  sudo cp ${CERT_FILE} /usr/local/share/ca-certificates/registry.crt"
            echo "  sudo update-ca-certificates"
            exit 1
        fi

        # Restart Docker if it's the runtime
        if [ "$RUNTIME" = "docker" ]; then
            echo "  Restarting Docker..."
            sudo systemctl restart docker
        fi
        ;;
    3)
        echo ""
        echo "Manual Configuration Instructions:"
        echo "==================================="
        echo ""
        echo "For Podman (per-registry):"
        echo "  sudo mkdir -p /etc/containers/certs.d/${REGISTRY_HOST}"
        echo "  sudo cp ${CERT_FILE} /etc/containers/certs.d/${REGISTRY_HOST}/ca.crt"
        echo ""
        echo "For Docker (per-registry):"
        echo "  sudo mkdir -p /etc/docker/certs.d/${REGISTRY_HOST}"
        echo "  sudo cp ${CERT_FILE} /etc/docker/certs.d/${REGISTRY_HOST}/ca.crt"
        echo "  sudo systemctl restart docker"
        echo ""
        echo "For system-wide trust (RHEL/Fedora/CentOS):"
        echo "  sudo cp ${CERT_FILE} /etc/pki/ca-trust/source/anchors/registry.crt"
        echo "  sudo update-ca-trust"
        echo ""
        echo "For system-wide trust (Debian/Ubuntu):"
        echo "  sudo cp ${CERT_FILE} /usr/local/share/ca-certificates/registry.crt"
        echo "  sudo update-ca-certificates"
        echo ""
        exit 0
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo ""
echo "Test the configuration:"
echo "  ${RUNTIME} login ${REGISTRY_HOST} -u sc-admin -p RegistryPass123!"
echo "  ${RUNTIME} pull nginx:latest"
echo "  ${RUNTIME} tag nginx:latest ${REGISTRY_HOST}/nginx:test"
echo "  ${RUNTIME} push ${REGISTRY_HOST}/nginx:test"
echo ""
