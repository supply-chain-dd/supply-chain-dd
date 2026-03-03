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

echo "✓ All prerequisites met"
echo ""

# Setup components
./scripts/setup-kind.sh
echo ""

./scripts/setup-tekton.sh
echo ""

echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Your CTF environment is ready to use."
echo ""
echo "Useful commands:"
echo "  kubectl get pods -A          # View all pods"
echo "  kubectl get pipelineruns     # View Tekton pipeline runs"
echo "  make status                  # Check environment status"
echo "  make clean                   # Cleanup environment"
