# ===============================
#  Dockerfile - GLPI 11.0.1 Auto
# ===============================

# Image de base
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# -------------------------------
# Installation Apache / PHP / MariaDB / Outils
# -------------------------------
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates tar unzip \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd \
      php-ldap php-intl php-mbstring php-zip php-imap \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache libsodium23 \
      util-linux && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# -------------------------------
# Télécharger et déployer GLPI
# -------------------------------
WORKDIR /tmp
RUN curl -fsSL -o glpi-11.0.1.tgz \
    https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz && \
    mkdir -p /var/www/html && \
    tar -xzf glpi-11.0.1.tgz -C /var/www/html --strip-components=1 && \
    rm -f glpi-11.0.1.tgz

# -------------------------------
# Configuration Apache
# -------------------------------
RUN a2enmod rewrite && rm -f /etc/apache2/sites-enabled/000-default.conf && \
    cat >/etc/apache2/sites-available/glpi.conf <<'EOF'
<VirtualHost *:80>
    ServerName _
    DocumentRoot /var/www/html/public
    DirectoryIndex index.php

    <Directory /var/www/html/public>
        Options -MultiViews +FollowSymLinks
        AllowOverride None
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule ^ index.php [QSA,L]
    </Directory>

    <Directory /var/www/html>
        Require all denied
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/glpi_error.log
    CustomLog ${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF
RUN a2ensite glpi

# -------------------------------
# Configuration PHP
# -------------------------------
RUN mkdir -p /etc/php/8.3/apache2/conf.d && \
    cat >/etc/php/8.3/apache2/conf.d/90-glpi.ini <<'INI'
memory_limit = 512M
session.use_strict_mode = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
;session.cookie_secure = 1
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
INI

# -------------------------------
# Permissions GLPI
# -------------------------------
RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
    done && \
    chown -R www-data:www-data /var/www/html && \
    find /var/www/html/files /var/www/html/config /var/www/html/marketplace -type d -exec chmod 775 {} \; && \
    find /var/www/html/files /var/www/html/config /var/www/html/marketplace -type f -exec chmod 664 {} \; && \
    find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# -------------------------------
# Configuration automatique de la base + installation GLPI
# -------------------------------
RUN service mariadb start && \
    sleep 5 && \
    # Créer la base et l'utilisateur
    mysql -uroot -e "CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" && \
    mysql -uroot -e "CREATE USER IF NOT EXISTS 'glpi'@'localhost' IDENTIFIED BY 'P@ssw0rd';" && \
    mysql -uroot -e "GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'localhost'; FLUSH PRIVILEGES;" && \
    # Installer GLPI (admin: admin / P@ssw0rd)
    runuser -u www-data -- php /var/www/html/bin/console database:install \
        --db-host=localhost \
        --db-name=glpi \
        --db-user=glpi \
        --db-password=P@ssw0rd \
        --admin-password="Admin123!" \
        --no-interaction \
        --force && \
    # Charger les timezones MySQL et activer dans GLPI
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot mysql && \
    runuser -u www-data -- php /var/www/html/bin/console db:enable_timezones --no-interaction

# -------------------------------
# Script d'init (runtime)
# -------------------------------
RUN printf '%s\n' \
'#!/usr/bin/env bash' \
'set -e' \
'service mariadb start' \
'sleep 3' \
'if [ ! -f /var/www/html/config/config_db.php ]; then' \
'  echo "[WARN] GLPI non détecté — tentative d’installation silencieuse..." >&2' \
'  runuser -u www-data -- php /var/www/html/bin/console database:install --db-host=localhost --db-name=glpi --db-user=glpi --db-password=P@ssw0rd --admin-password="Admin123!" --no-interaction --force || true' \
'  runuser -u www-data -- php /var/www/html/bin/console db:enable_timezones --no-interaction || true' \
'fi' \
'chown -R www-data:www-data /var/www/html' \
'exec apache2ctl -D FOREGROUND' \
> /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

# -------------------------------
# Ports et démarrage
# -------------------------------
EXPOSE 80
ENTRYPOINT ["/usr/local/bin/start.sh"]
