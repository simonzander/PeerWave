#!/bin/bash

# ============================================
# PeerWave Docker Build Script
# ============================================
# This script builds the Flutter web client and
# Docker image with the embedded web client
#
# Usage:
#   ./build-docker.sh [version] [--push]
#
# Example:
#   ./build-docker.sh v1.0.0
#   ./build-docker.sh v1.0.0 --push

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/client"
SERVER_DIR="$SCRIPT_DIR/server"
WEB_OUTPUT_DIR="$SERVER_DIR/web"

# Version from argument or version_config.yaml
VERSION=${1:-$(grep -oP 'version:\s*"\K[^"]+' "$SCRIPT_DIR/version_config.yaml" || echo "latest")}
PUSH_IMAGE=${2:-""}

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}PeerWave Docker Build Script${NC}"
echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}Version: $VERSION${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v flutter &> /dev/null; then
    echo -e "${RED}ERROR: Flutter is not installed or not in PATH${NC}"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}ERROR: Docker is not installed or not in PATH${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

# Step 1: Build Flutter Web Client
echo -e "${YELLOW}Step 1/4: Building Flutter web client...${NC}"
cd "$CLIENT_DIR"

echo "Running flutter pub get..."
flutter pub get

echo "Generating version info..."
cd "$SCRIPT_DIR"
dart run tools/generate_version.dart

cd "$CLIENT_DIR"
echo "Building web client (release mode)..."
flutter build web --release --web-renderer canvaskit

if [ ! -d "build/web" ]; then
    echo -e "${RED}ERROR: Flutter web build failed - build/web directory not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Flutter web build complete${NC}"
echo ""

# Step 2: Copy web build to server
echo -e "${YELLOW}Step 2/4: Copying web client to server...${NC}"

# Remove old web files
if [ -d "$WEB_OUTPUT_DIR" ]; then
    echo "Removing old web files..."
    rm -rf "$WEB_OUTPUT_DIR"
fi

# Copy new web files
echo "Copying build/web to server/web..."
cp -r "$CLIENT_DIR/build/web" "$WEB_OUTPUT_DIR"

echo -e "${GREEN}✓ Web client copied to server/web${NC}"
echo ""

# Step 3: Build Docker Image
echo -e "${YELLOW}Step 3/4: Building Docker image...${NC}"
cd "$SERVER_DIR"

DOCKER_IMAGE="simonzander/peerwave:$VERSION"
DOCKER_IMAGE_LATEST="simonzander/peerwave:latest"

echo "Building Docker image: $DOCKER_IMAGE"
docker build -t "$DOCKER_IMAGE" -t "$DOCKER_IMAGE_LATEST" .

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Docker build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker image built successfully${NC}"
echo -e "${GREEN}  Tagged as: $DOCKER_IMAGE${NC}"
echo -e "${GREEN}  Tagged as: $DOCKER_IMAGE_LATEST${NC}"
echo ""

# Step 4: Push to Docker Hub (optional)
if [ "$PUSH_IMAGE" == "--push" ]; then
    echo -e "${YELLOW}Step 4/4: Pushing to Docker Hub...${NC}"
    
    echo "Pushing $DOCKER_IMAGE..."
    docker push "$DOCKER_IMAGE"
    
    echo "Pushing $DOCKER_IMAGE_LATEST..."
    docker push "$DOCKER_IMAGE_LATEST"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Docker push failed${NC}"
        echo -e "${YELLOW}Make sure you're logged in: docker login${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Images pushed to Docker Hub${NC}"
else
    echo -e "${YELLOW}Step 4/4: Skipping Docker Hub push${NC}"
    echo -e "${YELLOW}  (Use './build-docker.sh $VERSION --push' to push)${NC}"
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${GREEN}✓ Build Complete!${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo -e "${GREEN}Docker Image: $DOCKER_IMAGE${NC}"
echo ""
echo -e "${YELLOW}To run locally:${NC}"
echo -e "  docker-compose up -d"
echo ""
echo -e "${YELLOW}To test the image:${NC}"
echo -e "  docker run -d -p 3000:3000 $DOCKER_IMAGE"
echo ""
