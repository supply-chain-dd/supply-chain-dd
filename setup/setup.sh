#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "CTF Environment Setup"
echo "=========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed"
    echo "Install from: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "Error: helm is not installed"
    echo "Install from: https://helm.sh/docs/intro/install/"
    exit 1
fi

echo "✓ All prerequisites met"
echo ""

# Setup components
./scripts/setup-kind.sh
echo ""

./scripts/setup-gitea.sh
echo ""

./scripts/setup-act-runner.sh
echo ""

echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Your CTF environment is ready to use."
echo ""
echo "Access Gitea:"
echo "  Web UI: http://localhost:30002"
echo "  Username: ctf-admin"
echo "  Password: CTFSecurePass123!"
echo ""
echo "Useful commands:"
echo "  kubectl get pods -A          # View all pods"
echo "  kubectl get pods -n gitea    # View Gitea pods"
echo "  make status                  # Check environment status"
echo "  make clean                   # Cleanup environment"
