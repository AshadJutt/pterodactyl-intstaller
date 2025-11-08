#!/usr/bin/env bash
# SkilloraClouds Installer
# Author: You
# Description: Installs SkilloraClouds Panel (based on Pterodactyl)

set -euo pipefail
LOG=/var/log/skillora-install.log
exec > >(tee -a "$LOG") 2>&1

echo "=========================================="
echo "      SkilloraClouds - Pterodactyl Installation Full Setup"
echo "=========================================="
sleep 1

# --- Ask for basic info ---
read -p "Enter your domain (e.g. panel.example.com): " DOMAIN
read -p "Enter your email for SSL certs: " EMAIL

echo
echo "[+] Updating system..."
apt update && apt upgrade -y
apt install -y curl git zip unzip tar nginx mariadb-server redis-server php8.1 php8.1-{cli,gd,curl,mbstring,xml,mysql,bcmath,zip,intl} composer

echo
echo "[+] Creating directory..."
mkdir -p /var/www/skilloraclouds
cd /var/www/skilloraclouds

echo
echo "[+] Downloading SkilloraClouds panel files..."
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz --strip-components=1
rm panel.tar.gz

echo
echo "[+] Setting up environment..."
cp .env.example .env
sed -i "s|APP_URL=http://localhost|APP_URL=https://$DOMAIN|g" .env

echo
echo "[+] Installing dependencies..."
composer install --no-dev --optimize-autoloader

echo
echo "[+] Generating app key..."
php artisan key:generate --force

echo
echo "[+] Running migrations..."
php artisan migrate --seed --force

echo
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

echo
echo "[+] Installing SSL certificate..."
apt install -y certbot python3-certbot-nginx
certbot --nginx -d $DOMAIN -m $EMAIL --agree-tos --redirect -n || true

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

echo
echo "=========================================="
echo "✅ SkilloraClouds installation completed!"
echo "Visit https://$DOMAIN to finish setup."
echo "Log file: $LOG"
echo "=========================================="
