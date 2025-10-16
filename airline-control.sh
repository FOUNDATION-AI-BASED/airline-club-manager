#!/bin/bash

# Airline Club Container Control Script
# Lightweight management script for low-end servers

set -e

# Configuration
CONTAINER_NAME="airline-club-server"
IMAGE_NAME="airline-club:v2.2"
WEB_PORT="9000"
DB_PORT="3306"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi
}

# Check if container exists
container_exists() {
    docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Check if container is running
container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Check if image exists
image_exists() {
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"
}

# Start the airline club
start_airline() {
    check_docker
    
    if ! image_exists; then
        log_error "Docker image '${IMAGE_NAME}' not found."
        log_info "Please build the image first or load it from a tar file:"
        log_info "  gunzip -c airline-club-v2.2.tar.gz | docker load"
        exit 1
    fi
    
    if container_running; then
        log_warning "Airline Club is already running"
        show_status
        return 0
    fi
    
    if container_exists; then
        log_info "Starting existing container..."
        docker start "${CONTAINER_NAME}"
    else
        log_info "Creating and starting new container..."
        docker run -d \
            --name "${CONTAINER_NAME}" \
            -p "${WEB_PORT}:9000" \
            -p "${DB_PORT}:3306" \
            --restart unless-stopped \
            "${IMAGE_NAME}"
    fi
    
    log_info "Waiting for services to start..."
    sleep 10
    
    # Wait for web server to be ready
    for i in {1..30}; do
        if curl -f "http://localhost:${WEB_PORT}/airlines" > /dev/null 2>&1; then
            log_success "Airline Club started successfully!"
            log_info "Web interface: http://localhost:${WEB_PORT}"
            return 0
        fi
        sleep 2
    done
    
    log_warning "Container started but web server may still be initializing"
    log_info "Check logs with: $0 logs"
}

# Stop the airline club
stop_airline() {
    check_docker
    
    if ! container_running; then
        log_warning "Airline Club is not running"
        return 0
    fi
    
    log_info "Stopping Airline Club..."
    docker stop "${CONTAINER_NAME}"
    log_success "Airline Club stopped"
}

# Restart the airline club
restart_airline() {
    stop_airline
    sleep 2
    start_airline
}

# Show status
show_status() {
    check_docker
    
    if ! image_exists; then
        log_error "Docker image '${IMAGE_NAME}' not found"
        return 1
    fi
    
    if container_running; then
        log_success "Airline Club is running"
        
        # Get container info
        CONTAINER_ID=$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.ID}}')
        UPTIME=$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Status}}')
        
        echo "Container ID: ${CONTAINER_ID}"
        echo "Status: ${UPTIME}"
        echo "Web interface: http://localhost:${WEB_PORT}"
        
        # Check if web server is responding
        if curl -f "http://localhost:${WEB_PORT}/airlines" > /dev/null 2>&1; then
            log_success "Web server is responding"
        else
            log_warning "Web server is not responding yet"
        fi
        
        # Show resource usage
        echo
        echo "Resource usage:"
        docker stats "${CONTAINER_NAME}" --no-stream --format "table {{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
        
    elif container_exists; then
        log_warning "Airline Club container exists but is not running"
        echo "Use '$0 start' to start it"
    else
        log_info "Airline Club container does not exist"
        echo "Use '$0 start' to create and start it"
    fi
}

# Show logs
show_logs() {
    check_docker
    
    if ! container_exists; then
        log_error "Container does not exist"
        exit 1
    fi
    
    local lines=${2:-50}
    local follow=${3:-false}
    
    if [ "$follow" = "true" ]; then
        docker logs -f --tail "$lines" "${CONTAINER_NAME}"
    else
        docker logs --tail "$lines" "${CONTAINER_NAME}"
    fi
}

# Remove container and volumes
remove_airline() {
    check_docker
    
    if container_running; then
        log_info "Stopping container first..."
        stop_airline
    fi
    
    if container_exists; then
        log_info "Removing container..."
        docker rm "${CONTAINER_NAME}"
        log_success "Container removed"
    else
        log_info "Container does not exist"
    fi
}

# Show help
show_help() {
    echo "Airline Club Container Control Script"
    echo
    echo "Usage: $0 <command> [options]"
    echo
    echo "Commands:"
    echo "  start     - Start the Airline Club container"
    echo "  stop      - Stop the Airline Club container"
    echo "  restart   - Restart the Airline Club container"
    echo "  status    - Show container status and resource usage"
    echo "  logs      - Show container logs (default: last 50 lines)"
    echo "  logs <n>  - Show last n lines of logs"
    echo "  logs <n> follow - Show last n lines and follow new logs"
    echo "  remove    - Remove the container (stops it first if running)"
    echo "  help      - Show this help message"
    echo
    echo "Examples:"
    echo "  $0 start                 # Start Airline Club"
    echo "  $0 status                # Check if running"
    echo "  $0 logs 100              # Show last 100 log lines"
    echo "  $0 logs 50 follow        # Follow logs"
    echo "  $0 restart               # Restart services"
    echo
    echo "Web interface will be available at: http://localhost:${WEB_PORT}"
}

# Main script logic
case "${1:-help}" in
    start)
        start_airline
        ;;
    stop)
        stop_airline
        ;;
    restart)
        restart_airline
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "$@"
        ;;
    remove)
        remove_airline
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        echo
        show_help
        exit 1
        ;;
esac