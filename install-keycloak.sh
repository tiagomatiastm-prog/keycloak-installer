#!/bin/bash
set -euo pipefail

#############################################
# Keycloak Installer for Debian 13
# Description: Automated installation of Keycloak SSO server with PostgreSQL
# Author: Tiago
# Date: 2025-11-08
#############################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
DEFAULT_DOMAIN="auth.ysalinde.fr"
DEFAULT_LISTEN_ADDRESS="127.0.0.1"
DEFAULT_HTTP_PORT="8080"
DEFAULT_ADMIN_USER="admin"
DEFAULT_BEHIND_PROXY="true"
INSTALL_DIR="/opt/keycloak"
DATA_DIR="${INSTALL_DIR}/data"
CONFIG_DIR="${INSTALL_DIR}/config"

# Initialize variables with defaults
DOMAIN="${DEFAULT_DOMAIN}"
LISTEN_ADDRESS="${DEFAULT_LISTEN_ADDRESS}"
HTTP_PORT="${DEFAULT_HTTP_PORT}"
ADMIN_USER="${DEFAULT_ADMIN_USER}"
ADMIN_PASSWORD=""
BEHIND_PROXY="${DEFAULT_BEHIND_PROXY}"
SKIP_DOCKER_INSTALL=false

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Install Keycloak SSO server with PostgreSQL via Docker.

OPTIONS:
    -d, --domain DOMAIN              Domain name for Keycloak (default: ${DEFAULT_DOMAIN})
    -l, --listen ADDRESS             Listen address (default: ${DEFAULT_LISTEN_ADDRESS} for reverse proxy)
    -p, --http-port PORT             HTTP port for Keycloak (default: ${DEFAULT_HTTP_PORT})
    -u, --admin-user USERNAME        Admin username (default: ${DEFAULT_ADMIN_USER})
    -P, --admin-password PASSWORD    Admin password (auto-generated if not provided)
    --behind-proxy [true|false]      Running behind reverse proxy (default: ${DEFAULT_BEHIND_PROXY})
    --skip-docker                    Skip Docker installation (use if already installed)
    -h, --help                       Show this help message

EXAMPLES:
    # Test installation with defaults (localhost)
    sudo $0

    # Production installation with domain
    sudo $0 --domain auth.example.com --admin-password MySecurePass123

    # Custom configuration
    sudo $0 --domain auth.local --http-port 9000 --listen 0.0.0.0 --behind-proxy false

NOTES:
    - This script must be run as root
    - Admin password will be auto-generated if not provided
    - If behind reverse proxy, configure HTTPS on your proxy (required for OAuth)
    - Default credentials will be stored in /root/keycloak-info.txt

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -l|--listen)
            LISTEN_ADDRESS="$2"
            shift 2
            ;;
        -p|--http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        -u|--admin-user)
            ADMIN_USER="$2"
            shift 2
            ;;
        -P|--admin-password)
            ADMIN_PASSWORD="$2"
            shift 2
            ;;
        --behind-proxy)
            BEHIND_PROXY="$2"
            shift 2
            ;;
        --skip-docker)
            SKIP_DOCKER_INSTALL=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

# Detect actual user (not root when using sudo)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo ~${ACTUAL_USER})

print_info "Starting Keycloak installation..."
print_info "Domain: ${DOMAIN}"
print_info "Listen Address: ${LISTEN_ADDRESS}"
print_info "HTTP Port: ${HTTP_PORT}"
print_info "Behind Reverse Proxy: ${BEHIND_PROXY}"

# Install Docker if needed
if [[ "${SKIP_DOCKER_INSTALL}" == false ]]; then
    if ! command -v docker &> /dev/null; then
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        print_info "Docker installed successfully"
    else
        print_info "Docker already installed, skipping..."
    fi
else
    print_info "Skipping Docker installation as requested"
fi

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
    print_error "Docker is not running. Please start Docker and try again."
    exit 1
fi

# Create directories
print_info "Creating directories..."
mkdir -p "${DATA_DIR}"/{postgres,keycloak,tmp}
mkdir -p "${CONFIG_DIR}"
chmod 755 "${INSTALL_DIR}"
chmod 755 "${DATA_DIR}"
chmod 777 "${DATA_DIR}/tmp"  # Temporary directory needs to be writable by Keycloak container

# Generate secure passwords and secrets
print_info "Generating secure passwords and secrets..."
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

if [[ -z "${ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    print_info "Admin password auto-generated"
else
    print_info "Using provided admin password"
fi

DB_USER="keycloak"
DB_NAME="keycloak"

# Set Keycloak URL based on configuration
if [[ "${BEHIND_PROXY}" == "true" ]]; then
    KEYCLOAK_URL="https://${DOMAIN}"
else
    KEYCLOAK_URL="http://${DOMAIN}:${HTTP_PORT}"
fi

# Create .env file
print_info "Creating environment configuration..."
cat > "${CONFIG_DIR}/.env" << EOF
# Keycloak Configuration
# Generated on $(date)

# Domain Configuration
KEYCLOAK_DOMAIN=${DOMAIN}
KEYCLOAK_URL=${KEYCLOAK_URL}

# Network Configuration
LISTEN_ADDRESS=${LISTEN_ADDRESS}
HTTP_PORT=${HTTP_PORT}

# Admin Credentials
KEYCLOAK_ADMIN=${ADMIN_USER}
KEYCLOAK_ADMIN_PASSWORD=${ADMIN_PASSWORD}

# Database Configuration
DB_VENDOR=postgres
DB_ADDR=postgres
DB_DATABASE=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}

# PostgreSQL
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASSWORD}

# Reverse Proxy Configuration
BEHIND_REVERSE_PROXY=${BEHIND_PROXY}
PROXY_ADDRESS_FORWARDING=true

# Keycloak Settings
KC_HOSTNAME=${DOMAIN}
KC_HOSTNAME_STRICT=false
KC_HOSTNAME_STRICT_HTTPS=false
KC_HTTP_ENABLED=true
KC_HEALTH_ENABLED=true
KC_METRICS_ENABLED=true
KC_LOG_LEVEL=info
EOF

chmod 600 "${CONFIG_DIR}/.env"

# Create docker-compose.yml
print_info "Creating Docker Compose configuration..."
cat > "${INSTALL_DIR}/docker-compose.yml" << 'EOFCOMPOSE'
services:
  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: keycloak-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - keycloak-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Keycloak SSO Server
  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: keycloak
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      # Admin credentials
      KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}

      # Database
      KC_DB: postgres
      KC_DB_URL_HOST: postgres
      KC_DB_URL_DATABASE: ${DB_DATABASE}
      KC_DB_USERNAME: ${DB_USER}
      KC_DB_PASSWORD: ${DB_PASSWORD}

      # Hostname configuration
      KC_HOSTNAME: ${KC_HOSTNAME}
      KC_HOSTNAME_STRICT: ${KC_HOSTNAME_STRICT}
      KC_HOSTNAME_STRICT_HTTPS: ${KC_HOSTNAME_STRICT_HTTPS}

      # HTTP configuration
      KC_HTTP_ENABLED: ${KC_HTTP_ENABLED}
      KC_HTTP_PORT: ${HTTP_PORT}

      # Proxy configuration
      KC_PROXY: edge
      KC_PROXY_HEADERS: xforwarded

      # Observability
      KC_HEALTH_ENABLED: ${KC_HEALTH_ENABLED}
      KC_METRICS_ENABLED: ${KC_METRICS_ENABLED}
      KC_LOG_LEVEL: ${KC_LOG_LEVEL}
    volumes:
      - ./data/keycloak:/opt/keycloak/data
    ports:
      - "${LISTEN_ADDRESS}:${HTTP_PORT}:${HTTP_PORT}"
    networks:
      - keycloak-network
    command:
      - start
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/${HTTP_PORT};echo -e 'GET /health/ready HTTP/1.1\r\nhost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3;grep 'HTTP/1.1 200 OK' <&3"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s

networks:
  keycloak-network:
    driver: bridge
EOFCOMPOSE

# Create systemd service for docker-compose
print_info "Creating systemd service..."
cat > /etc/systemd/system/keycloak.service << EOF
[Unit]
Description=Keycloak SSO Server (Docker Compose)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_DIR}/.env
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start service
print_info "Starting Keycloak services..."
systemctl daemon-reload
systemctl enable keycloak.service
systemctl start keycloak.service

# Wait for services to be ready
print_info "Waiting for services to start (this may take 1-2 minutes)..."
sleep 30

# Check if services are running
if systemctl is-active --quiet keycloak.service; then
    print_info "Keycloak services started successfully!"
else
    print_error "Failed to start Keycloak services"
    systemctl status keycloak.service
    exit 1
fi

# Wait a bit more for Keycloak to be fully ready
print_info "Waiting for Keycloak to be fully initialized..."
sleep 30

# Create info file
INFO_FILE="/root/keycloak-info.txt"
print_info "Creating information file at ${INFO_FILE}..."

cat > "${INFO_FILE}" << EOF
========================================
  KEYCLOAK SSO SERVER INSTALLATION INFO
========================================
Installation Date: $(date)
Domain: ${DOMAIN}

========================================
  ACCESS INFORMATION
========================================
Admin Console: ${KEYCLOAK_URL}/admin
Account Console: ${KEYCLOAK_URL}/realms/master/account

$(if [[ "${BEHIND_PROXY}" == "true" ]]; then
    echo "REVERSE PROXY CONFIGURATION:"
    echo "  Configure your reverse proxy to forward:"
    echo "  - https://${DOMAIN} -> http://${LISTEN_ADDRESS}:${HTTP_PORT}"
    echo ""
    echo "  Required headers:"
    echo "  - X-Forwarded-For"
    echo "  - X-Forwarded-Proto"
    echo "  - X-Forwarded-Host"
    echo ""
fi)

========================================
  ADMIN CREDENTIALS
========================================
Username: ${ADMIN_USER}
Password: ${ADMIN_PASSWORD}

⚠️  IMPORTANT: Change the admin password after first login!

========================================
  DATABASE CREDENTIALS
========================================
PostgreSQL Host: postgres (internal)
Database: ${DB_NAME}
Username: ${DB_USER}
Password: ${DB_PASSWORD}

========================================
  SYSTEM INFORMATION
========================================
Installation Directory: ${INSTALL_DIR}
Data Directory: ${DATA_DIR}
Configuration: ${CONFIG_DIR}/.env
Docker Compose: ${INSTALL_DIR}/docker-compose.yml

Service Management:
  Start:   sudo systemctl start keycloak
  Stop:    sudo systemctl stop keycloak
  Restart: sudo systemctl restart keycloak
  Status:  sudo systemctl status keycloak
  Logs:    sudo docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f keycloak

========================================
  ENDPOINTS
========================================
Admin Console: ${KEYCLOAK_URL}/admin
Master Realm: ${KEYCLOAK_URL}/realms/master
Health Check: ${KEYCLOAK_URL}/health
Metrics: ${KEYCLOAK_URL}/metrics

OpenID Configuration: ${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration

========================================
  FIREWALL REQUIREMENTS
========================================
Required ports (open in firewall):
  - ${HTTP_PORT}/tcp (Keycloak HTTP)

If NOT behind reverse proxy:
  - Allow external access to port ${HTTP_PORT}

If behind reverse proxy:
  - Only reverse proxy needs access to ${HTTP_PORT}
  - Open 443/tcp on reverse proxy for HTTPS

========================================
  NEXT STEPS
========================================
1. Access the Admin Console at ${KEYCLOAK_URL}/admin
2. Login with credentials above
3. Change the admin password
4. Create a new realm for your applications
5. Configure clients (OAuth/OIDC applications)
6. $(if [[ "${BEHIND_PROXY}" == "true" ]]; then echo "Configure your reverse proxy with HTTPS"; else echo "Consider setting up HTTPS with reverse proxy"; fi)

========================================
  COMMON TASKS
========================================

Create a new realm:
  1. Admin Console → Realms → Create Realm
  2. Name your realm (e.g., "mycompany")

Create an OAuth client (for applications):
  1. Select your realm
  2. Clients → Create Client
  3. Client type: OpenID Connect
  4. Configure redirect URIs
  5. Save client ID and secret

User management:
  - Users → Add user
  - Set password (temporary or permanent)
  - Assign roles

========================================
  TROUBLESHOOTING
========================================
View Keycloak logs:
  sudo docker logs keycloak -f

View all container logs:
  sudo docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f

Check container status:
  sudo docker ps | grep keycloak

Restart services:
  sudo systemctl restart keycloak

Access database:
  sudo docker exec -it keycloak-postgres psql -U ${DB_USER} -d ${DB_NAME}

========================================
  BACKUP
========================================
Important files to backup:
  - ${DATA_DIR}/ (all application data)
  - ${CONFIG_DIR}/.env (configuration)
  - ${INSTALL_DIR}/docker-compose.yml

Backup command:
  sudo tar czf keycloak-backup-\$(date +%Y%m%d).tar.gz ${INSTALL_DIR}

Database backup:
  sudo docker exec keycloak-postgres pg_dump -U ${DB_USER} ${DB_NAME} > keycloak-db-backup.sql

========================================
  DOCUMENTATION
========================================
Official Keycloak Documentation: https://www.keycloak.org/documentation
Server Administration Guide: https://www.keycloak.org/docs/latest/server_admin/
OAuth/OIDC Guide: https://www.keycloak.org/docs/latest/securing_apps/

========================================
EOF

chmod 600 "${INFO_FILE}"

# Display summary
print_info "========================================="
print_info "  KEYCLOAK INSTALLATION COMPLETE!"
print_info "========================================="
print_info ""
print_info "Admin Console: ${KEYCLOAK_URL}/admin"
print_info "Username: ${ADMIN_USER}"
print_info "Password: ${ADMIN_PASSWORD}"
print_info ""
print_info "Full details saved to: ${INFO_FILE}"
print_info ""
if [[ "${BEHIND_PROXY}" == "true" ]]; then
    print_warn "⚠ Configure your reverse proxy to forward traffic to Keycloak"
    print_warn "⚠ HTTPS is required for OAuth/OIDC to work properly"
    print_warn "⚠ Proxy must forward: X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host headers"
fi
print_info ""
print_info "Next steps:"
print_info "  1. Access the Admin Console and change the admin password"
print_info "  2. Create a new realm for your applications"
print_info "  3. Configure OAuth clients for your apps"
print_info ""
print_info "Service management:"
print_info "  sudo systemctl status keycloak"
print_info "  sudo docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f keycloak"
print_info ""
print_info "========================================="
