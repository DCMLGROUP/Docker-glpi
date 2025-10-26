# Image de base
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Mises à jour + Apache/PHP/MariaDB + outils + certificats
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates tar unzip \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd \
      php-ldap php-intl php-mbstring php-zip php-imap && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Télécharger GLPI via curl (HTTPS vérifié)
WORKDIR /tmp
RUN curl -fsSL -o glpi-11.0.1.tgz \
    https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz

# Déployer GLPI dans /var/www/html
RUN mkdir -p /var/www/html && \
    tar -xzf /tmp/glpi-11.0.1.tgz -C /var/www/html --strip-components=1 && \
    rm -f /tmp/glpi-11.0.1.tgz

# Apache: activer rewrite et vhost GLPI sur /public (sans .htaccess)
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

# Extensions PHP supplémentaires (Ubuntu 24.04 / PHP 8.3)
RUN apt-get update && apt-get install -y --no-install-recommends \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache libsodium23 && \
    rm -rf /var/lib/apt/lists/*

# Réglages PHP recommandés pour GLPI
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

# Dossiers requis + permissions
RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
      chown -R www-data:www-data "$d"; \
      find "$d" -type d -exec chmod 775 {} \; ; \
      find "$d" -type f -exec chmod 664 {} \; ; \
    done && \
    chown -R www-data:www-data /var/www/html && \
    find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# Script d'init MariaDB + lancement Apache
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -e' \
  'service mariadb start' \
  'sleep 5' \
  'mysql -uroot -e "ALTER USER '\''root'\''@'\''localhost'\'' IDENTIFIED BY '\''P@ssw0rd'\''; FLUSH PRIVILEGES;"' \
  'mysql -uroot -pP@ssw0rd -e "CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"' \
  'mysql -uroot -pP@ssw0rd -e "CREATE USER IF NOT EXISTS '\''glpi'\''@'\''localhost'\'' IDENTIFIED BY '\''P@ssw0rd'\'';"' \
  'mysql -uroot -pP@ssw0rd -e "GRANT ALL PRIVILEGES ON glpi.* TO '\''glpi'\''@'\''localhost'\''; FLUSH PRIVILEGES;"' \
  'exec apache2ctl -D FOREGROUND' \
  > /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/start.sh"]
