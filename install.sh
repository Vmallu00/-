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
# OPTION 1: Install Panel (unchanged)
# ============================================================
install_panel() {
    echo -e "${GREEN}===== Installing Pterodactyl Panel =====${NC}"
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

    apt update && apt upgrade -y
    apt install -y software-properties-common curl git unzip nginx \
        mariadb-server redis-server supervisor \
        php8.1 php8.1-fpm php8.1-cli php8.1-common php8.1-gd \
        php8.1-mysql php8.1-mbstring php8.1-bcmath php8.1-xml \
        php8.1-curl php8.1-zip php8.1-posix php8.1-imap \
        php8.1-intl php8.1-readline

    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt install -y nodejs

    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;"

    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl
    git clone --depth=1 https://github.com/pterodactyl/panel.git .
    cp .env.example .env
    composer install --no-dev --optimize-autoloader

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
# OPTION 2: Install Wings (unchanged)
# ============================================================
install_wings() {
    echo -e "${GREEN}===== Installing Wings (Daemon) =====${NC}"
    echo -e "${YELLOW}This will install Docker and Wings, then connect to your Panel.${NC}"
    
    read -p "Enter your Panel URL (e.g., https://panel.example.com or http://192.168.1.10): " PANEL_URL
    read -p "Enter the Node token (generated from Panel → Nodes → Create Node): " NODE_TOKEN

    if [[ -z "$PANEL_URL" || -z "$NODE_TOKEN" ]]; then
        echo -e "${RED}Panel URL and token are required. Aborting.${NC}"
        return
    fi

    if ! ask_yes_no "Continue with Wings installation?"; then
        return
    fi

    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable --now docker

    export PANEL_URL="$PANEL_URL"
    export TOKEN="$NODE_TOKEN"
    bash <(curl -s https://pterodactyl-installer.se) wings

    if systemctl is-active --quiet wings; then
        echo -e "${GREEN}Wings is running and connected to your Panel.${NC}"
    else
        echo -e "${YELLOW}Wings installation finished, but service may not be active. Check with: systemctl status wings${NC}"
    fi
    echo -e "${GREEN}Wings installation complete.${NC}"
}

# ============================================================
# OPTION 3: Uninstall Panel + Wings (unchanged)
# ============================================================
uninstall_all() {
    echo -e "${RED}===== UNINSTALL PANEL + WINGS =====${NC}"
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - Panel files and database"
    echo "  - Wings and its Docker containers"
    echo "  - Nginx and Supervisor configurations"
    echo ""
    if ! ask_yes_no "Are you sure you want to proceed with complete uninstallation?"; then
        return
    fi

    supervisorctl stop pterodactyl-worker || true
    systemctl stop nginx || true

    rm -f /etc/nginx/sites-available/pterodactyl.conf
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf
    nginx -t && systemctl restart nginx || true

    rm -f /etc/supervisor/conf.d/pterodactyl-worker.conf
    supervisorctl reread || true
    supervisorctl update || true

    if [[ -f /var/www/pterodactyl/.env ]]; then
        source /var/www/pterodactyl/.env
        DB_HOST=${DB_HOST:-127.0.0.1}
        DB_DATABASE=${DB_DATABASE:-pterodactyl}
        DB_USERNAME=${DB_USERNAME:-pterodactyl}
        if [[ -n "$DB_DATABASE" && -n "$DB_USERNAME" ]]; then
            mysql -h ${DB_HOST} -u root -e "DROP DATABASE IF EXISTS ${DB_DATABASE};" || true
            mysql -h ${DB_HOST} -u root -e "DROP USER IF EXISTS '${DB_USERNAME}'@'127.0.0.1';" || true
            mysql -h ${DB_HOST} -u root -e "FLUSH PRIVILEGES;" || true
        fi
    else
        echo -e "${YELLOW}.env not found; skipping database drop.${NC}"
    fi

    rm -rf /var/www/pterodactyl

    systemctl stop wings || true
    systemctl disable wings || true
    rm -f /etc/systemd/system/wings.service
    rm -f /usr/local/bin/wings
    rm -rf /etc/pterodactyl
    rm -rf /var/lib/pterodactyl
    docker stop wings 2>/dev/null || true
    docker rm wings 2>/dev/null || true

    if ask_yes_no "Do you also want to remove Docker completely?"; then
        apt purge -y docker-ce docker-ce-cli containerd.io
        rm -rf /var/lib/docker
        echo -e "${GREEN}Docker removed.${NC}"
    fi

    echo -e "${GREEN}Uninstallation complete.${NC}"
}

# ============================================================
# VM MANAGEMENT (KVM) – now accepts ANY ALLOW_NO_SYSTEMD value
# ============================================================

check_systemd_or_allow() {
    if [[ -d /run/systemd/system ]]; then
        # systemd is present – all good
        return 0
    fi

    # No systemd – check if user set ALLOW_NO_SYSTEMD to any non-empty value
    if [[ -n "${ALLOW_NO_SYSTEMD}" ]]; then
        echo -e "${YELLOW}WARNING: systemd not found, but ALLOW_NO_SYSTEMD is set.${NC}"
        echo -e "${YELLOW}Will attempt to start libvirtd manually.${NC}"
        return 0
    else
        echo -e "${RED}ERROR: This script requires systemd (PID 1) to manage KVM VMs.${NC}"
        echo -e "${RED}You are running in a container or environment without systemd.${NC}"
        echo -e "${RED}To override this check, set environment variable: ALLOW_NO_SYSTEMD=1${NC}"
        echo -e "${RED}Example: ALLOW_NO_SYSTEMD=1 ./pterodactyl-manager.sh${NC}"
        exit 1
    fi
}

ensure_kvm() {
    # First, check if we can proceed without systemd
    check_systemd_or_allow

    # Install KVM packages if missing
    if ! dpkg -l | grep -q qemu-kvm; then
        echo -e "${YELLOW}Installing KVM/libvirt packages...${NC}"
        apt update
        apt install -y qemu-kvm libvirt-daemon-system virtinst cpu-checker whois
    fi

    # If systemd is missing, try to start libvirtd manually
    if [[ ! -d /run/systemd/system ]]; then
        echo -e "${YELLOW}Starting libvirtd manually (since systemd is not available)...${NC}"
        # Kill any existing libvirtd
        pkill libvirtd 2>/dev/null || true
        # Start libvirtd as daemon
        libvirtd -d
        # Wait for socket
        sleep 2
    else
        # Use systemd if available
        systemctl enable --now libvirtd
    fi

    # Check KVM acceleration
    if ! kvm-ok 2>/dev/null | grep -q "KVM acceleration can be used"; then
        echo -e "${YELLOW}WARNING: KVM acceleration not available. VM will run in software emulation (slow).${NC}"
    else
        echo -e "${GREEN}KVM acceleration is available.${NC}"
    fi
}

list_vms() {
    echo -e "${BLUE}===== Existing VMs =====${NC}"
    local vms=$(virsh list --all --name)
    if [[ -z "$vms" ]]; then
        echo -e "${YELLOW}No VMs found.${NC}"
        return 1
    fi
    printf "%-20s %-12s %-10s %-12s %-10s\n" "VM Name" "Status" "CPU %" "RAM (MB)" "Disk (GB)"
    printf "%-20s %-12s %-10s %-12s %-10s\n" "--------" "------" "-----" "-------" "--------"
    for vm in $vms; do
        state=$(virsh domstate "$vm" 2>/dev/null | head -n1)
        if [[ "$state" == "running" ]]; then
            status="🟢 Online"
        elif [[ "$state" == "shut off" ]]; then
            status="🔴 Offline"
        else
            status="$state"
        fi
        if [[ "$state" == "running" ]]; then
            stats=$(virsh domstats "$vm" --cpu-total --balloon 2>/dev/null)
            cpu_time=$(echo "$stats" | grep "cpu.time" | awk -F'=' '{print $2}' | head -1)
            cpu_time=${cpu_time:-0}
            cpu_usage="N/A"
            mem_rss=$(echo "$stats" | grep "balloon.rss" | awk -F'=' '{print $2}' | head -1)
            mem_rss=${mem_rss:-0}
            mem_mb=$((mem_rss / 1024))
        else
            cpu_usage="N/A"
            mem_mb=0
        fi
        disk_file=$(virsh domblklist "$vm" | awk '/disk/ {print $2}' | head -1)
        if [[ -n "$disk_file" && -f "$disk_file" ]]; then
            disk_size=$(du -b "$disk_file" 2>/dev/null | awk '{print $1}')
            disk_gb=$(echo "scale=2; $disk_size / 1073741824" | bc 2>/dev/null || echo "0")
        else
            disk_gb="0"
        fi
        printf "%-20s %-12s %-10s %-12s %-10s\n" "$vm" "$status" "$cpu_usage" "$mem_mb" "$disk_gb"
    done
    echo ""
    return 0
}

create_vm() {
    echo -e "${GREEN}===== Create a New VM (KVM) =====${NC}"
    ensure_kvm

    read -p "Enter VM name (e.g., my-vm): " VM_NAME
    read -p "Enter RAM in MB (default 2048): " RAM
    RAM=${RAM:-2048}
    read -p "Enter number of vCPUs (default 2): " CPU
    CPU=${CPU:-2}
    read -p "Enter disk size in GB (default 20): " DISK
    DISK=${DISK:-20}
    read -p "Enter network (default: virbr0 for NAT, or bridge name): " NETWORK
    NETWORK=${NETWORK:-virbr0}

    echo -e "${BLUE}Select OS:${NC}"
    echo "1) Ubuntu 24.04 (Noble)"
    echo "2) Debian 12 (Bookworm)"
    read -p "Choice [1-2]: " OS_CHOICE

    case $OS_CHOICE in
        1)
            OS_NAME="Ubuntu 24.04"
            LOCATION="http://archive.ubuntu.com/ubuntu/dists/noble/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/"
            ;;
        2)
            OS_NAME="Debian 12"
            LOCATION="http://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/"
            ;;
        *)
            echo -e "${RED}Invalid choice. Aborting.${NC}"
            return
            ;;
    esac

    read -p "Enter username for the VM: " VM_USER
    read -sp "Enter password for $VM_USER: " VM_PASS
    echo ""
    read -sp "Enter root password for the VM: " ROOT_PASS
    echo ""

    USER_HASH=$(mkpasswd -m sha-512 "$VM_PASS")
    ROOT_HASH=$(mkpasswd -m sha-512 "$ROOT_PASS")

    PRESEED_FILE="/tmp/preseed-${VM_NAME}.cfg"
    cat > "$PRESEED_FILE" <<EOF
# Preseed for $OS_NAME

d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i console-setup/ask_detect boolean false
d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 60
d-i mirror/country string manual
d-i mirror/http/hostname string archive.ubuntu.com
d-i mirror/http/directory string /ubuntu
d-i mirror/http/proxy string
d-i time/zone string UTC
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i passwd/root-login boolean true
d-i passwd/root-password-crypted password $ROOT_HASH
d-i passwd/user-fullname string $VM_USER
d-i passwd/username string $VM_USER
d-i passwd/user-password-crypted password $USER_HASH
d-i passwd/user-default-groups string sudo
tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string default
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string \
    in-target systemctl set-default multi-user.target
EOF

    echo -e "${GREEN}Preseed file created at $PRESEED_FILE${NC}"

    echo -e "${GREEN}Starting VM creation... This may take several minutes.${NC}"
    virt-install \
        --name "$VM_NAME" \
        --ram "$RAM" \
        --vcpus "$CPU" \
        --disk size="$DISK" \
        --network network="$NETWORK" \
        --location "$LOCATION" \
        --initrd-inject "$PRESEED_FILE" \
        --extra-args "preseed/file=/preseed.cfg console-setup/ask_detect=false console-setup/layoutcode=us keyboard-configuration/xkb-keymap=us locale=en_US.UTF-8" \
        --noautoconsole \
        --graphics none

    echo -e "${GREEN}VM creation initiated.${NC}"
    echo -e "You can connect to the console using: ${BLUE}virsh console $VM_NAME${NC}"
    echo -e "VM login: $VM_USER / password: (your chosen password)"
    echo -e "Root password: (your chosen root password)"
}

start_vm() {
    read -p "Enter the VM name to start: " VM_NAME
    if ! virsh list --all --name | grep -qx "$VM_NAME"; then
        echo -e "${RED}VM '$VM_NAME' does not exist.${NC}"
        return
    fi
    if virsh domstate "$VM_NAME" | grep -q running; then
        echo -e "${YELLOW}VM '$VM_NAME' is already running.${NC}"
    else
        virsh start "$VM_NAME"
        echo -e "${GREEN}VM '$VM_NAME' started.${NC}"
    fi
}

stop_vm() {
    read -p "Enter the VM name to stop: " VM_NAME
    if ! virsh list --all --name | grep -qx "$VM_NAME"; then
        echo -e "${RED}VM '$VM_NAME' does not exist.${NC}"
        return
    fi
    if virsh domstate "$VM_NAME" | grep -q shut; then
        echo -e "${YELLOW}VM '$VM_NAME' is already off.${NC}"
    else
        virsh shutdown "$VM_NAME"
        echo -e "${GREEN}Shutdown signal sent to '$VM_NAME'.${NC}"
        echo -e "${YELLOW}You can force stop with: virsh destroy $VM_NAME${NC}"
    fi
}

console_vm() {
    read -p "Enter the VM name to console into: " VM_NAME
    if ! virsh list --all --name | grep -qx "$VM_NAME"; then
        echo -e "${RED}VM '$VM_NAME' does not exist.${NC}"
        return
    fi
    if virsh domstate "$VM_NAME" | grep -q shut; then
        echo -e "${RED}VM '$VM_NAME' is not running.${NC}"
        if ask_yes_no "Would you like to start it now?"; then
            virsh start "$VM_NAME"
            echo -e "${GREEN}Started. Connecting to console...${NC}"
            virsh console "$VM_NAME"
        else
            echo -e "${YELLOW}Returning to menu.${NC}"
        fi
    else
        echo -e "${GREEN}Connecting to console of '$VM_NAME'. Press Ctrl+] to exit.${NC}"
        virsh console "$VM_NAME"
    fi
}

vm_management() {
    ensure_kvm
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}     VM Management (KVM)              ${NC}"
        echo -e "${BLUE}========================================${NC}"
        list_vms
        echo -e "${BLUE}========================================${NC}"
        echo "1. Create a new VM"
        echo "2. Start a VM"
        echo "3. Stop a VM"
        echo "4. Console to a VM"
        echo "5. Back to main menu"
        read -p "Enter your choice [1-5]: " choice
        case $choice in
            1) create_vm ;;
            2) start_vm ;;
            3) stop_vm ;;
            4) console_vm ;;
            5) break ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
        read -p "Press Enter to continue..."
    done
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
    echo "4. Manage VMs (KVM)"
    echo "5. Exit"
    echo ""
    read -p "Enter your choice [1-5]: " choice
    case $choice in
        1) install_panel ;;
        2) install_wings ;;
        3) uninstall_all ;;
        4) vm_management ;;
        5) echo -e "${GREEN}Exiting.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1; show_menu ;;
    esac
}

show_menu
