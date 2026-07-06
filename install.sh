#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root.${NC}"
   exit 1
fi

# --- OS Check (Ubuntu 22.04 / 24.04) ---
if [[ ! -f /etc/os-release ]]; then
    echo -e "${RED}Unsupported OS. Only Ubuntu 22.04/24.04 is supported.${NC}"
    exit 1
fi
. /etc/os-release
if [[ "$ID" != "ubuntu" ]] || [[ ! "$VERSION_ID" =~ ^(22.04|24.04)$ ]]; then
    echo -e "${RED}Supported only on Ubuntu 22.04 or 24.04.${NC}"
    exit 1
fi

# --- Helper: ask yes/no ---
ask_yes_no() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# ============================================================
# FUNCTION: Install Panel
# ============================================================
install_panel() {
    echo -e "${GREEN}===== Installing Pterodactyl Panel =====${NC}"
    # Get user inputs
    read -p "Enter your panel domain or IP (e.g., panel.example.com or 192.168.1.10): " FQDN
    read -sp "Enter a password for MariaDB root user (save this): " MYSQL_ROOT_PASS
    echo ""
    read -p "Enter database name (e.g., pterodactyl): " DB_NAME
    read -p "Enter database username: " DB_USER
    read -sp "Enter database user password: " DB_PASS
    echo ""
    read -p "Enter admin email for the panel: " ADMIN_EMAIL
    read -p "Enter admin username: " ADMIN_USER
    read -sp "Enter admin password: " ADMIN_PASS
    echo ""

    # System update
    apt update && apt upgrade -y

    # Dependencies
    apt install -y software-properties-common curl git unzip nginx \
        mariadb-server redis-server supervisor \
        php8.1 php8.1-fpm php8.1-cli php8.1-common php8.1-gd \
        php8.1-mysql php8.1-mbstring php8.1-bcmath php8.1-xml \
        php8.1-curl php8.1-zip php8.1-posix php8.1-imap \
        php8.1-intl php8.1-readline

    # Composer
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    # Node.js
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt install -y nodejs

    # Secure MariaDB
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;"

    # Clone panel
    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl
    git clone --depth=1 https://github.com/pterodactyl/panel.git .
    cp .env.example .env

    composer install --no-dev --optimize-autoloader

    # Database
    mysql -u root -p${MYSQL_ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
    mysql -u root -p${MYSQL_ROOT_PASS} -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
    mysql -u root -p${MYSQL_ROOT_PASS} -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;"

    php artisan key:generate --force
    sed -i "s|APP_URL=.*|APP_URL=http://${FQDN}|g" .env
    sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
    sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
    sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env

    php artisan migrate --seed --force
    php artisan p:user:make --email=${ADMIN_EMAIL} --username=${ADMIN_USER} --password=${ADMIN_PASS} --no-interaction

    chown -R www-data:www-data /var/www/pterodactyl/*
    chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

    # Supervisor worker
    cat > /etc/supervisor/conf.d/pterodactyl-worker.conf <<EOF
[program:pterodactyl-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
autostart=true
autorestart=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/var/www/pterodactyl/storage/logs/worker.log
stopwaitsecs=60
EOF
    supervisorctl reread
    supervisorctl update

    # Nginx
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${FQDN};
    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    # Optional SSL
    if ask_yes_no "Do you want to enable HTTPS via Let's Encrypt? (requires a valid domain)"; then
        apt install -y certbot python3-certbot-nginx
        certbot --nginx -d ${FQDN} --non-interactive --agree-tos --email ${ADMIN_EMAIL}
        systemctl reload nginx
    fi

    echo -e "${GREEN}Panel installation complete!${NC}"
    echo -e "Access: ${BLUE}http://${FQDN}${NC}"
    echo -e "Admin: ${ADMIN_USER} / Password: ${ADMIN_PASS}"
    echo -e "${YELLOW}After logging in, go to 'Nodes' to create a node and generate a token for Wings.${NC}"
}

# ============================================================
# FUNCTION: Install Wings (auto‑connect to Panel)
# ============================================================
install_wings() {
    echo -e "${GREEN}===== Installing Wings (Daemon) =====${NC}"
    echo -e "${YELLOW}This will install Docker and Wings, then automatically connect it to your Panel.${NC}"
    
    read -p "Enter your Panel URL (e.g., https://panel.example.com or http://192.168.1.10): " PANEL_URL
    read -p "Enter the Node token (generated from Panel → Nodes → Create Node): " NODE_TOKEN

    if [[ -z "$PANEL_URL" || -z "$NODE_TOKEN" ]]; then
        echo -e "${RED}Panel URL and token are required. Aborting.${NC}"
        return
    fi

    if ! ask_yes_no "Continue with Wings installation?"; then
        return
    fi

    # Install Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable --now docker

    # Install Wings using the official installer with environment variables for auto‑configuration
    echo -e "${GREEN}Running official Wings installer with auto‑connect...${NC}"
    export PANEL_URL="$PANEL_URL"
    export TOKEN="$NODE_TOKEN"
    # The installer will pick up these env vars and skip interactive prompts
    bash <(curl -s https://pterodactyl-installer.se) wings

    # Check if Wings service is running
    if systemctl is-active --quiet wings; then
        echo -e "${GREEN}Wings is running and connected to your Panel.${NC}"
    else
        echo -e "${YELLOW}Wings installation finished, but service may not be active. Check with: systemctl status wings${NC}"
    fi

    echo -e "${GREEN}Wings installation complete.${NC}"
}

# ============================================================
# FUNCTION: Uninstall Panel + Wings (complete removal)
# ============================================================
uninstall_all() {
    echo -e "${RED}===== UNINSTALL PANEL + WINGS =====${NC}"
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - Panel files and database"
    echo "  - Wings and its Docker containers (if any)"
    echo "  - Nginx and Supervisor configurations"
    echo "  - The panel's MariaDB database and user"
    echo ""
    if ! ask_yes_no "Are you sure you want to proceed with complete uninstallation?"; then
        return
    fi

    # Stop and remove panel-related services
    echo -e "${YELLOW}Stopping panel services...${NC}"
    supervisorctl stop pterodactyl-worker || true
    systemctl stop nginx || true

    # Remove Nginx site
    rm -f /etc/nginx/sites-available/pterodactyl.conf
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf
    nginx -t && systemctl restart nginx || true

    # Remove Supervisor config
    rm -f /etc/supervisor/conf.d/pterodactyl-worker.conf
    supervisorctl reread || true
    supervisorctl update || true

    # Drop the database (if we can get credentials from .env)
    if [[ -f /var/www/pterodactyl/.env ]]; then
        source /var/www/pterodactyl/.env
        DB_HOST=${DB_HOST:-127.0.0.1}
        DB_DATABASE=${DB_DATABASE:-pterodactyl}
        DB_USERNAME=${DB_USERNAME:-pterodactyl}
        DB_PASSWORD=${DB_PASSWORD:-}
        if [[ -n "$DB_DATABASE" && -n "$DB_USERNAME" ]]; then
            mysql -h ${DB_HOST} -u root -e "DROP DATABASE IF EXISTS ${DB_DATABASE};" || true
            mysql -h ${DB_HOST} -u root -e "DROP USER IF EXISTS '${DB_USERNAME}'@'127.0.0.1';" || true
            mysql -h ${DB_HOST} -u root -e "FLUSH PRIVILEGES;" || true
        fi
    else
        echo -e "${YELLOW}.env not found; skipping database drop.${NC}"
    fi

    # Remove panel directory
    rm -rf /var/www/pterodactyl

    # Remove Wings (if installed)
    echo -e "${YELLOW}Removing Wings...${NC}"
    systemctl stop wings || true
    systemctl disable wings || true
    rm -f /etc/systemd/system/wings.service
    rm -f /usr/local/bin/wings
    rm -rf /etc/pterodactyl
    rm -rf /var/lib/pterodactyl
    # Stop and remove any Wings container (if still running)
    docker stop wings 2>/dev/null || true
    docker rm wings 2>/dev/null || true

    # Remove Docker? We'll keep Docker installed but optionally ask
    if ask_yes_no "Do you also want to remove Docker completely?"; then
        apt purge -y docker-ce docker-ce-cli containerd.io
        rm -rf /var/lib/docker
        echo -e "${GREEN}Docker removed.${NC}"
    fi

    echo -e "${GREEN}Uninstallation complete.${NC}"
}

# ============================================================
# MAIN MENU
# ============================================================
show_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Pterodactyl Manager Script         ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1. Install Pterodactyl Panel"
    echo "2. Install Wings (Daemon) – auto‑connect to Panel"
    echo "3. Uninstall Panel + Wings (complete removal)"
    echo "4. Exit"
    echo ""
    read -p "Enter your choice [1-4]: " choice
    case $choice in
        1) install_panel ;;
        2) install_wings ;;
        3) uninstall_all ;;
        4) echo -e "${GREEN}Exiting.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1; show_menu ;;
    esac
}

# Run menu
show_menu
