k#!/bin/bash
# build-unprivileged.sh
# Build and push nginx-s3-gateway unprivileged to Docker Hub
# Usage: ./build-unprivileged.sh [NGINX_VERSION]
# Example: ./build-unprivileged.sh 1.30.1

set -e

# Config
NGINX_VERSION="${1:-1.30.1}"
DOCKER_REPO="silentk/nginx-s3-gateway"
PLATFORM="linux/amd64"
LOCAL_BASE_TAG="nginx-s3-gateway"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Build nginx-s3-gateway unprivileged                       ║${NC}"
echo -e "${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC}  Nginx version : ${GREEN}${NGINX_VERSION}${NC}"
echo -e "${BLUE}║${NC}  Docker repo   : ${GREEN}${DOCKER_REPO}${NC}"
echo -e "${BLUE}║${NC}  Platform      : ${GREEN}${PLATFORM}${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check that we are in the correct directory
if [[ ! -f "Dockerfile.oss" ]] || [[ ! -f "Dockerfile.unprivileged" ]]; then
    echo -e "${RED}✗ Error: Dockerfile.oss or Dockerfile.unprivileged not found${NC}"
    echo "  Run this script from the cloned nginx-s3-gateway directory"
    exit 1
fi

# Check that Dockerfile.oss uses the right nginx version
if ! grep -q "FROM nginx:${NGINX_VERSION}" Dockerfile.oss; then
    echo -e "${YELLOW}⚠ Warning: Dockerfile.oss does not contain 'FROM nginx:${NGINX_VERSION}'${NC}"
    echo "  Current version in Dockerfile.oss:"
    grep "^FROM nginx" Dockerfile.oss | sed 's/^/    /'
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled. Update Dockerfile.oss with:"
        echo "  sed -i 's|FROM nginx:.*|FROM nginx:${NGINX_VERSION}|' Dockerfile.oss"
        exit 1
    fi
fi

# Check Docker Hub login
echo -e "${YELLOW}→ Checking Docker Hub login...${NC}"
if ! docker info 2>/dev/null | grep -q "Username:"; then
    echo -e "${YELLOW}  Not logged in to Docker Hub, running docker login${NC}"
    docker login
fi
echo -e "${GREEN}  ✓ Login OK${NC}"
echo ""

# Step 1: Build the base image
echo -e "${BLUE}=== [1/3] Building base image (Dockerfile.oss) ===${NC}"
docker buildx build \
    --platform "${PLATFORM}" \
    --file Dockerfile.oss \
    --load \
    --pull \
    -t "${LOCAL_BASE_TAG}" \
    .

echo -e "${GREEN}✓ Base image built: ${LOCAL_BASE_TAG}${NC}"
echo ""

# Verify nginx version in the base image
echo -e "${YELLOW}→ Verifying nginx version in the base image...${NC}"
ACTUAL_VERSION=$(docker run --rm --entrypoint nginx "${LOCAL_BASE_TAG}" -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
if [[ -z "${ACTUAL_VERSION}" ]]; then
    ACTUAL_VERSION="unknown"
fi
echo -e "  Version found: ${GREEN}nginx ${ACTUAL_VERSION}${NC}"

if [[ "${ACTUAL_VERSION}" != "${NGINX_VERSION}" ]]; then
    echo -e "${RED}✗ Version mismatch (expected: ${NGINX_VERSION}, found: ${ACTUAL_VERSION})${NC}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
echo ""

# Step 2: Build and push the unprivileged image
echo -e "${BLUE}=== [2/3] Building and pushing the unprivileged image ===${NC}"
echo -e "  Tags: ${GREEN}${DOCKER_REPO}:${NGINX_VERSION}-unprivileged${NC}"
echo -e "        ${GREEN}${DOCKER_REPO}:latest${NC}"
echo ""

docker buildx build \
    --platform "${PLATFORM}" \
    --file Dockerfile.unprivileged \
    -t "${DOCKER_REPO}:${NGINX_VERSION}-unprivileged" \
    -t "${DOCKER_REPO}:latest" \
    --push \
    .

echo -e "${GREEN}✓ Unprivileged image built and pushed${NC}"
echo ""

# Step 3: Final verification
echo -e "${BLUE}=== [3/3] Final verification ===${NC}"
echo -e "${YELLOW}→ Pulling the pushed image for validation...${NC}"

docker pull "${DOCKER_REPO}:${NGINX_VERSION}-unprivileged" --platform "${PLATFORM}"

FINAL_VERSION=$(docker run --rm --entrypoint nginx "${DOCKER_REPO}:${NGINX_VERSION}-unprivileged" -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
if [[ -z "${FINAL_VERSION}" ]]; then
    FINAL_VERSION="unknown"
fi
echo -e "  Version in the pushed image: ${GREEN}nginx ${FINAL_VERSION}${NC}"

if [[ "${FINAL_VERSION}" == "${NGINX_VERSION}" ]]; then
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ Build and push successful                               ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Image available at:"
    echo -e "${GREEN}║${NC}    ${DOCKER_REPO}:${NGINX_VERSION}-unprivileged"
    echo -e "${GREEN}║${NC}    ${DOCKER_REPO}:latest"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  To use it:"
    echo -e "${GREEN}║${NC}    docker pull ${DOCKER_REPO}:${NGINX_VERSION}-unprivileged"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
else
    echo ""
    echo -e "${RED}✗ Final version does not match (expected: ${NGINX_VERSION}, found: ${FINAL_VERSION})${NC}"
    exit 1
fi
