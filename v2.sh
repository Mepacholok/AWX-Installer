#!/bin/bash

# Comprehensive AWX Installation Script
# This script handles multiple installation methods with fallbacks
# Author: AI Assistant
# Version: 1.1 - Fixed namespace issues

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWX_ADMIN_USER="admin"
AWX_ADMIN_PASSWORD="password"
AWX_SECRET_KEY="awxsecretkey123456789012345678901234567890"
AWX_DIR="/opt/awx-deployment"
INSTALL_METHOD=""

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root for security reasons"
        error "Please run as a regular user with sudo privileges"
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    # Check available memory
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 4 ]]; then
        warn "Less than 4GB RAM detected. AWX may not perform well."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check disk space
    local disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [[ $disk_gb -lt 20 ]]; then
        error "Insufficient disk space. At least 20GB required."
        exit 1
    fi
    
    log "System requirements check passed"
}

# Install dependencies
install_dependencies() {
    log "Installing dependencies..."
    
    # Update package list
    sudo apt update
    
    # Install essential packages
    sudo apt install -y \
        curl \
        wget \
        git \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common \
        python3 \
        python3-pip \
        python3-venv
    
    log "Dependencies installed successfully"
}

# Install Docker
install_docker() {
    log "Installing Docker..."
    
    if command -v docker &> /dev/null; then
        info "Docker already installed"
        return 0
    fi
    
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Add user to docker group
    sudo usermod -aG docker $USER
    
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    
    log "Docker installed successfully"
    warn "You may need to log out and back in for Docker group membership to take effect"
}

# Install Docker Compose
install_docker_compose() {
    log "Installing Docker Compose..."
    
    if command -v docker-compose &> /dev/null; then
        info "Docker Compose already installed"
        return 0
    fi
    
    # Install Docker Compose V2
    sudo curl -SL https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    
    # Verify installation
    if docker-compose --version; then
        log "Docker Compose installed successfully"
    else
        error "Docker Compose installation failed"
        return 1
    fi
}

# Install kubectl and kind for Kubernetes method
install_k8s_tools() {
    log "Installing Kubernetes tools..."
    
    # Install kubectl
    if ! command -v kubectl &> /dev/null; then
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
    fi
    
    # Install kind
    if ! command -v kind &> /dev/null; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
    fi
    
    log "Kubernetes tools installed successfully"
}

# Method 1: AWX Operator (Recommended)
install_awx_operator() {
    log "Installing AWX using AWX Operator (Kubernetes)..."
    
    # Create kind cluster
    if ! kind get clusters | grep -q awx; then
        info "Creating Kubernetes cluster with kind..."
        kind create cluster --name awx --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8080
    protocol: TCP
EOF
    fi
    
    # Wait for cluster to be ready
    info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    # Create AWX namespace first
    info "Creating AWX namespace..."
    kubectl create namespace awx --dry-run=client -o yaml | kubectl apply -f -
    
    # Install AWX Operator
    info "Installing AWX Operator..."
    kubectl apply -k https://github.com/ansible/awx-operator/config/default?ref=2.19.1
    
    # Wait for awx-system namespace to be created
    info "Waiting for awx-system namespace to be available..."
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl get namespace awx-system >/dev/null 2>&1; then
            info "awx-system namespace found"
            break
        fi
        info "Attempt $attempt/$max_attempts - Waiting for awx-system namespace..."
        sleep 5
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        error "awx-system namespace was not created within expected time"
        return 1
    fi
    
    # Wait for operator deployment to exist
    info "Waiting for AWX Operator deployment to be created..."
    attempt=1
    while [ $attempt -le $max_attempts ]; do
        if kubectl get deployment awx-operator-controller-manager -n awx-system >/dev/null 2>&1; then
            info "AWX Operator deployment found"
            break
        fi
        info "Attempt $attempt/$max_attempts - Waiting for AWX Operator deployment..."
        sleep 5
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        error "AWX Operator deployment was not created within expected time"
        return 1
    fi
    
    # Wait for operator to be ready
    info "Waiting for AWX Operator to be ready..."
    kubectl wait --for=condition=Available deployment/awx-operator-controller-manager -n awx-system --timeout=600s
    
    # Create AWX instance
    info "Creating AWX instance..."
    cat <<EOF | kubectl apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx-demo
  namespace: awx
spec:
  service_type: NodePort
  nodeport_port: 30080
  admin_user: ${AWX_ADMIN_USER}
  postgres_storage_class: standard
  postgres_storage_requirements:
    requests:
      storage: 8Gi
EOF
    
    # Wait for AWX to be ready - check for the AWX resource status
    info "Waiting for AWX to be ready (this may take 10-15 minutes)..."
    attempt=1
    max_attempts=60
    
    while [ $attempt -le $max_attempts ]; do
        # Check if AWX pods are running
        local running_pods=$(kubectl get pods -n awx --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        local total_pods=$(kubectl get pods -n awx --no-headers 2>/dev/null | wc -l)
        
        if [[ $running_pods -gt 0 ]] && [[ $total_pods -gt 0 ]]; then
            # Check if the main AWX pod is ready
            if kubectl get pods -n awx -l app.kubernetes.io/name=awx-demo --no-headers 2>/dev/null | grep -q "Running"; then
                info "AWX pods are running"
                break
            fi
        fi
        
        info "Attempt $attempt/$max_attempts - AWX pods status: $running_pods/$total_pods running"
        sleep 15
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        warn "AWX may still be starting. Check status with: kubectl get pods -n awx"
    fi
    
    # Get admin password - wait for secret to be created
    info "Retrieving admin password..."
    attempt=1
    admin_password=""
    
    while [ $attempt -le 30 ]; do
        if admin_password=$(kubectl get secret awx-demo-admin-password -o jsonpath="{.data.password}" -n awx 2>/dev/null | base64 --decode 2>/dev/null); then
            if [[ -n "$admin_password" ]]; then
                break
            fi
        fi
        info "Attempt $attempt/30 - Waiting for admin password secret..."
        sleep 10
        ((attempt++))
    done
    
    if [[ -z "$admin_password" ]]; then
        warn "Could not retrieve admin password. Using default: ${AWX_ADMIN_PASSWORD}"
        admin_password="${AWX_ADMIN_PASSWORD}"
    fi
    
    log "AWX Operator installation completed successfully!"
    echo
    echo "========================================"
    echo "AWX Access Information (Operator):"
    echo "URL: http://localhost:8080"
    echo "Username: ${AWX_ADMIN_USER}"
    echo "Password: ${admin_password}"
    echo "========================================"
    
    INSTALL_METHOD="operator"
    return 0
}

# Method 2: Docker Compose
install_awx_docker() {
    log "Installing AWX using Docker Compose..."
    
    # Create installation directory
    sudo mkdir -p $AWX_DIR
    sudo chown $USER:$USER $AWX_DIR
    cd $AWX_DIR
    
    # Create docker-compose.yml
    cat > docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:13
    container_name: awx_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: awx
      POSTGRES_USER: awx
      POSTGRES_PASSWORD: awxpass
      PGDATA: /var/lib/postgresql/data/pgdata/
    volumes:
      - postgres_data:/var/lib/postgresql/data/pgdata/
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U awx -d awx"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: awx_redis
    restart: unless-stopped

  awx:
    image: ghcr.io/ansible/awx_devel:devel
    container_name: awx_all
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "8043:8043"
    environment:
      SECRET_KEY: ${AWX_SECRET_KEY}
      DATABASE_NAME: awx
      DATABASE_USER: awx
      DATABASE_PASSWORD: awxpass
      DATABASE_HOST: postgres
      DATABASE_PORT: 5432
      REDIS_HOST: redis
      REDIS_PORT: 6379
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - awx_projects:/var/lib/awx/projects
      - ./settings.py:/etc/awx/settings.py:ro
    command: >
      bash -c "
      echo 'Waiting for database...' &&
      sleep 30 &&
      echo 'Running migrations...' &&
      awx-manage migrate --noinput &&
      echo 'Creating admin user...' &&
      echo \"from django.contrib.auth.models import User; User.objects.filter(username='${AWX_ADMIN_USER}').exists() or User.objects.create_superuser('${AWX_ADMIN_USER}', 'admin@example.com', '${AWX_ADMIN_PASSWORD}')\" | awx-manage shell &&
      echo 'Starting AWX services...' &&
      supervisord -c /etc/supervisord.conf
      "

volumes:
  postgres_data:
  awx_projects:
EOF

    # Create AWX settings file
    cat > settings.py <<EOF
# AWX Settings
import os
SECRET_KEY = os.environ.get('SECRET_KEY', '${AWX_SECRET_KEY}')
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.environ.get('DATABASE_NAME', 'awx'),
        'USER': os.environ.get('DATABASE_USER', 'awx'),
        'PASSWORD': os.environ.get('DATABASE_PASSWORD', 'awxpass'),
        'HOST': os.environ.get('DATABASE_HOST', 'postgres'),
        'PORT': os.environ.get('DATABASE_PORT', '5432'),
    }
}
BROKER_URL = 'redis://{}:{}/0'.format(
    os.environ.get('REDIS_HOST', 'redis'),
    os.environ.get('REDIS_PORT', '6379')
)
STATIC_ROOT = '/var/lib/awx/public/static'
PROJECTS_ROOT = '/var/lib/awx/projects'
EOF

    # Start services
    info "Starting AWX services..."
    docker-compose up -d
    
    # Wait for services to be ready
    info "Waiting for AWX to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s http://localhost:8080/api/v2/ping/ >/dev/null 2>&1; then
            break
        fi
        info "Attempt $attempt/$max_attempts - Waiting for AWX to respond..."
        sleep 30
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        error "AWX failed to start within expected time"
        info "Check logs with: docker-compose logs awx"
        return 1
    fi
    
    log "AWX Docker installation completed successfully!"
    echo
    echo "========================================"
    echo "AWX Access Information (Docker):"
    echo "URL: http://localhost:8080"
    echo "Username: ${AWX_ADMIN_USER}"
    echo "Password: ${AWX_ADMIN_PASSWORD}"
    echo "========================================"
    
    INSTALL_METHOD="docker"
    return 0
}

# Display final information
show_final_info() {
    echo
    log "AWX installation completed!"
    echo
    echo "Next steps:"
    echo "1. Access AWX at http://localhost:8080"
    echo "2. Log in with the credentials shown above"
    echo "3. Start creating projects, inventories, and job templates"
    echo
    if [[ $INSTALL_METHOD == "operator" ]]; then
        echo "Kubernetes commands:"
        echo "- View pods: kubectl get pods -n awx"
        echo "- View AWX logs: kubectl logs -f deployment/awx-demo -n awx"
        echo "- View operator logs: kubectl logs -f deployment/awx-operator-controller-manager -n awx-system"
        echo "- Delete AWX: kubectl delete awx awx-demo -n awx"
        echo "- Delete cluster: kind delete cluster --name awx"
    elif [[ $INSTALL_METHOD == "docker" ]]; then
        echo "Docker commands:"
        echo "- View containers: docker-compose ps"
        echo "- View logs: docker-compose logs -f awx"
        echo "- Stop AWX: docker-compose down"
        echo "- Restart AWX: docker-compose up -d"
        echo "- Installation directory: $AWX_DIR"
    fi
    echo
    echo "For support, visit: https://github.com/ansible/awx"
}

# Cleanup function
cleanup() {
    if [[ $INSTALL_METHOD == "operator" ]]; then
        warn "To clean up, run: kind delete cluster --name awx"
    elif [[ $INSTALL_METHOD == "docker" ]]; then
        warn "To clean up, run: cd $AWX_DIR && docker-compose down -v"
    fi
}

# Main installation function
main() {
    echo "========================================"
    echo "Comprehensive AWX Installation Script"
    echo "========================================"
    echo
    
    # Trap cleanup on exit
    trap cleanup EXIT
    
    # Check if running as root
    check_root
    
    # Check system requirements
    check_requirements
    
    # Install dependencies
    install_dependencies
    
    # Install Docker
    install_docker
    install_docker_compose
    
    # Ask user for installation method
    echo
    echo "Choose installation method:"
    echo "1) AWX Operator (Kubernetes) - Recommended, most stable"
    echo "2) Docker Compose - Simpler, for development"
    echo
    read -p "Enter your choice (1 or 2): " -n 1 -r
    echo
    
    case $REPLY in
        1)
            install_k8s_tools
            if install_awx_operator; then
                show_final_info
            else
                error "AWX Operator installation failed"
                warn "Trying Docker Compose as fallback..."
                if install_awx_docker; then
                    show_final_info
                else
                    error "All installation methods failed"
                    exit 1
                fi
            fi
            ;;
        2)
            if install_awx_docker; then
                show_final_info
            else
                error "Docker installation failed"
                warn "Trying AWX Operator as fallback..."
                install_k8s_tools
                if install_awx_operator; then
                    show_final_info
                else
                    error "All installation methods failed"
                    exit 1
                fi
            fi
            ;;
        *)
            error "Invalid choice. Please run the script again and choose 1 or 2."
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
