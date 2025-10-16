#!/bin/bash

# Airline Club Docker Image Builder
# Run this script on a powerful machine to pre-build the heavy database operations

set -e

# Configuration
IMAGE_NAME="airline-club"
IMAGE_TAG="v2.2"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    log_error "Docker Compose is not available. Please install Docker Compose."
    exit 1
fi

log_info "Starting Airline Club Docker image build process..."
log_info "This will pre-compile airline-data and initialize the database."
log_info "Image: ${FULL_IMAGE_NAME}"

# Ensure we're in the right directory
if [ ! -f "Dockerfile" ] || [ ! -f "airline_manager.py" ]; then
    log_error "Please run this script from the airline-club-manager directory."
    exit 1
fi

# Check if airline directory exists
if [ ! -d "airline" ]; then
    log_error "Airline source code directory not found. Please ensure 'airline' directory exists."
    exit 1
fi

# Build the Docker image
log_info "Building Docker image (this may take 10-30 minutes depending on hardware)..."
log_info "Heavy operations (sbt compilation, database initialization) will be done now."

if docker build -t "${FULL_IMAGE_NAME}" . --no-cache; then
    log_success "Docker image built successfully: ${FULL_IMAGE_NAME}"
else
    log_error "Failed to build Docker image"
    exit 1
fi

# Get image size
IMAGE_SIZE=$(docker images "${FULL_IMAGE_NAME}" --format "table {{.Size}}" | tail -n 1)
log_info "Image size: ${IMAGE_SIZE}"

# Test the image
log_info "Testing the built image..."
if docker run --rm -d --name airline-test -p 9001:9000 "${FULL_IMAGE_NAME}" > /dev/null; then
    log_info "Waiting for services to start (60 seconds)..."
    sleep 60
    
    # Check if web server is responding
    if curl -f http://localhost:9001/airlines > /dev/null 2>&1; then
        log_success "Image test passed - web server is responding"
    else
        log_warning "Web server test failed, but image was built successfully"
    fi
    
    # Stop test container
    docker stop airline-test > /dev/null 2>&1 || true
else
    log_warning "Could not start test container, but image was built successfully"
fi

log_success "Build process completed!"
log_info "To save the image for deployment on another machine:"
log_info "  docker save ${FULL_IMAGE_NAME} | gzip > airline-club-v2.2.tar.gz"
log_info ""
log_info "To load the image on the target machine:"
log_info "  gunzip -c airline-club-v2.2.tar.gz | docker load"
log_info ""
log_info "To run the container:"
log_info "  docker-compose up -d"
log_info "  # OR"
log_info "  docker run -d --name airline-club -p 9000:9000 ${FULL_IMAGE_NAME}"

echo
log_success "Airline Club Docker image is ready for deployment!"