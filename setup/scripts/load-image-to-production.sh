#!/bin/bash
#
# Load recipe-api image into production cluster
# This makes the CTF cluster's registry image available in the production cluster
#

set -euo pipefail

CLUSTER_NAME="${PRODUCTION_CLUSTER_NAME:-ctf-production-cluster}"
IMAGE="${RECIPE_API_IMAGE:-localhost:30000/recipe-api:v1.0}"

echo "==> Loading recipe-api image into production cluster..."

# Verify production cluster exists
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "Error: Production cluster '${CLUSTER_NAME}' not found."
    echo "Run 'make setup-production-cluster' first."
    exit 1
fi

# Determine container runtime to use (respect CONTAINER_RUNTIME env var if set)
RUNTIME="${CONTAINER_RUNTIME:-}"

if [ -n "$RUNTIME" ]; then
    # CONTAINER_RUNTIME is set, use it exclusively
    echo "Using CONTAINER_RUNTIME=$RUNTIME"
    if ! command -v "$RUNTIME" &> /dev/null; then
        echo "Error: CONTAINER_RUNTIME is set to '$RUNTIME' but it's not installed."
        exit 1
    fi

    # Check if image exists in the specified runtime
    if [ "$RUNTIME" = "podman" ]; then
        if ! podman image exists "$IMAGE" 2>/dev/null; then
            echo "Error: Image '$IMAGE' not found in Podman."
            echo "Build the image first: CONTAINER_RUNTIME=podman make build-recipe-api"
            exit 1
        fi
    else
        if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo "Error: Image '$IMAGE' not found in Docker."
            echo "Build the image first: CONTAINER_RUNTIME=docker make build-recipe-api"
            exit 1
        fi
    fi
    echo "✓ Found image in $RUNTIME: $IMAGE"
else
    # Auto-detect which runtime has the image
    echo "Checking if image exists locally..."
    if podman image exists "$IMAGE" 2>/dev/null; then
        echo "✓ Found image in Podman: $IMAGE"
        RUNTIME="podman"
    elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "✓ Found image in Docker: $IMAGE"
        RUNTIME="docker"
    else
        echo "Error: Image '$IMAGE' not found in Podman or Docker."
        echo ""
        echo "Build the image first:"
        echo "  make build-recipe-api"
        exit 1
    fi
fi

# Create temporary directory for image archive
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

IMAGE_ARCHIVE="$TEMP_DIR/recipe-api.tar"

# Save image to tar archive
echo "Saving image to temporary archive..."
if [ "$RUNTIME" = "podman" ]; then
    podman save -o "$IMAGE_ARCHIVE" "$IMAGE"
else
    docker save -o "$IMAGE_ARCHIVE" "$IMAGE"
fi

# Load image archive into production cluster
echo "Loading image archive into production cluster..."
kind load image-archive "$IMAGE_ARCHIVE" --name "$CLUSTER_NAME"

echo ""
echo "✓ Image loaded successfully into production cluster!"
echo ""
echo "The production cluster can now pull: $IMAGE"
echo ""
