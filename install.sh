#!/usr/bin/env bash
# SkilloraClouds Full Pterodactyl Setup Installer
# Supports Ubuntu 22.04 / 24.04 only
set -euo pipefail
LOG=/var/log/skillora-install.log
exec > >(tee -a "$LOG") 2>&1

# -----------------------------
# Check OS version
# -----------------------------
OS_NAME=$(lsb_release -si)
OS_VER=$(lsb_release -sr)

if [[ "$OS_NAME" != "Ubuntu" ]]; then
    echo "❌ This installer only supports Ubuntu 22.04 and 24.04"
    exit 1
fi

if [[ "$OS_VER" != "22.04" && "$OS_VER" != "24.04" ]]; then
    echo "❌ Unsupported Ubuntu version: $OS_VER"
    echo "Please use Ubuntu 22.04 or 24.04"
    exit 1
fi

echo "✅ Detected supported OS: $OS_NAME $OS_VER"

# -----------------------------
# Default flags
# -----------------------------
INSTALL_PANEL=${INSTALL_PANEL:-true}
INSTALL_WINGS=${INSTALL_WINGS:-true}
UNINSTALL_PANEL=${UNINSTALL_PANEL:-false}
UNINSTALL_WINGS=${UNINSTALL_WINGS:-false}
DOMAIN=${DOMAIN:-""}
EMAIL=${EMAIL:-""}

# -----------------------------
# SkilloraClouds Banner
# -----------------------------
echo -e "\e[95m"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 🚀 SkilloraClouds Installer 🚀               ║"
echo "║           Full Pterodactyl Panel + Wings Setup              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "\e[0m"
sleep 1

# -----------------------------
# Interactive domain/email
# -----------------------------
if [ -z "$DOMAIN" ]; then
    read -p "Enter your domain (e.g. panel.skillora.cloud): " DOMAIN
fi

if [ -z "$EMAIL" ]; then
    read -p "Enter your email for SSL certs: " EMAIL
fi

# -----------------------------
# Interactive menu
# -----------------------------
echo
echo "Select an option:"
echo "1) Install Panel only"
echo "2) Install Wings only"
echo "3) Install Both Panel + Wings"
echo "4) Uninstall Panel only"
echo "5) Uninstall Wings only"
echo "6) Uninstall Both Panel + Wings"
read -p "Enter your choice [1-6]: " choice

case $choice in
  1) INSTALL_PANEL=true; INSTALL_WINGS=false ;;
  2) INSTALL_PANEL=false; INSTALL_WINGS=true ;;
  3) INSTALL_PANEL=true; INSTALL_WINGS=true ;;
  4) UNINSTALL_PANEL=true; INSTALL_PANEL=false; INSTALL_WINGS=false ;;
  5) UNINSTALL_WINGS=true; INSTALL_PANEL=false; INSTALL_WINGS=false ;;
  6) UNINSTALL_PANEL=true; UNINSTALL_WINGS=true; INSTALL_PANEL=false; INSTALL_WINGS=false ;;
  *) echo "Invalid choice. Exiting."; exit 1 ;;
esac

# -----------------------------
# Add PHP PPA and install dependencies
# -----------------------------
if [ "$INSTALL_PANEL" = true ] || [ "$INSTALL_WINGS" = true ]; then
    echo "[+] Adding PHP repository and installing dependencies..."
    apt update && apt install -y software-properties-common curl
    add-apt-repository -y ppa:ondrej/php
    apt update

    # PHP 8.1 + extensions required for Pterodactyl
    apt install -y php8.1 php8.1-cli php8.1-gd php8.1-curl php8.1-mbstring \
                   php8.1-xml php8.1-mysql php8.1-bcmath php8.1-zip php8.1-intl \
                   composer nginx mariadb-server redis-server git zip unzip tar \
                   certbot python3-certbot-nginx

    # Verify PHP installation
    php -v || { echo "❌ PHP installation failed! Exiting."; exit 1; }
fi

# -----------------------------
# Panel Installation
# -----------------------------
if [ "$INSTALL_PANEL" = true ]; then
    echo
    echo "[+] Installing Panel..."
    mkdir -p /var/www/skilloraclouds
    cd /var/www/skilloraclouds

    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz --strip-components=1
    rm panel.tar.gz

    cp .env.example .env
    sed -i "s|APP_URL=http://localhost|APP_URL=https://$DOMAIN|g" .env

    echo "[+] Installing PHP dependencies..."
    composer install --no-dev --optimize-autoloader

    echo "[+] Generating app key..."
    php artisan key:generate --force

    echo "[+] Running migrations..."
    php artisan migrate --seed --force

    echo "[+] Configuring Nginx..."
    cat >/etc/nginx/sites-available/skilloraclouds.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/skilloraclouds/public;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/skilloraclouds.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx

    echo "[+] Installing SSL certificate..."
    certbot --nginx -d $DOMAIN -m $EMAIL --agree-tos --redirect -n || true
fi

# -----------------------------
# Wings Installation
# -----------------------------
if [ "$INSTALL_WINGS" = true ]; then
    echo
    echo "[+] Installing Wings..."
    curl -L -o /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
    chmod +x /usr/local/bin/wings
    mkdir -p /etc/skilloraclouds

    cat >/etc/systemd/system/wings.service <<EOF
[Unit]
Description=SkilloraClouds Wings
After=docker.service network.target
Requires=docker.service

[Service]
User=root
ExecStart=/usr/local/bin/wings
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wings.service
fi

# -----------------------------
# Uninstallation
# -----------------------------
if [ "$UNINSTALL_PANEL" = true ]; then
    echo
    echo "[+] Uninstalling Panel..."
    systemctl stop nginx || true
    rm -rf /var/www/skilloraclouds
    rm -f /etc/nginx/sites-available/skilloraclouds.conf
    rm -f /etc/nginx/sites-enabled/skilloraclouds.conf
    nginx -t && systemctl reload nginx || true
fi

if [ "$UNINSTALL_WINGS" = true ]; then
    echo
    echo "[+] Uninstalling Wings..."
    systemctl stop wings.service || true
    systemctl disable wings.service || true
    rm -f /usr/local/bin/wings
    rm -rf /etc/skilloraclouds
    rm -f /etc/systemd/system/wings.service
    systemctl daemon-reload
fi

# -----------------------------
# Completion Banner
# -----------------------------
echo
echo "╔═══════════════════════════════════════════════════════╗"
echo "✅ SkilloraClouds operation completed!"
echo "Log file: $LOG"
if [ "$INSTALL_PANEL" = true ] || [ "$INSTALL_WINGS" = true ]; then
    echo "Visit: https://$DOMAIN (if installed)"
fi
echo "╚═══════════════════════════════════════════════════════╝"
