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
    bash -lc "cat > /etc/apache2/sites-available/glpi.conf <<'EOF'\n\
<VirtualHost *:80>\n\
    ServerName _\n\
    DocumentRoot /var/www/html/public\n\
    DirectoryIndex index.php\n\
\n\
    <Directory /var/www/html/public>\n\
        Options -MultiViews +FollowSymLinks\n\
        AllowOverride None\n\
        Require all granted\n\
        RewriteEngine On\n\
        RewriteCond %{REQUEST_FILENAME} !-f\n\
        RewriteCond %{REQUEST_FILENAME} !-d\n\
        RewriteRule ^ index.php [QSA,L]\n\
    </Directory>\n\
\n\
    <Directory /var/www/html>\n\
        Require all denied\n\
    </Directory>\n\
\n\
    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log\n\
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined\n\
</VirtualHost>\n\
EOF" && \
    a2ensite glpi

# Extensions PHP supplémentaires (Ubuntu 24.04 / PHP 8.3)
RUN apt-get update && apt-get install -y --no-install-recommends \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache libsodium23 && \
    rm -rf /var/lib/apt/lists/*

# Réglages PHP recommandés pour GLPI
RUN mkdir -p /etc/php/8.3/apache2/conf.d && \
    bash -lc "cat > /etc/php/8.3/apache2/conf.d/90-glpi.ini <<'INI'\n\
memory_limit = 512M\n\
session.use_strict_mode = 1\n\
session.use_only_cookies = 1\n\
session.cookie_httponly = 1\n\
;session.cookie_secure = 1\n\
opcache.enable=1\n\
opcache.memory_consumption=128\n\
opcache.interned_strings_buffer=16\n\
opcache.max_accelerated_files=10000\n\
opcache.revalidate_freq=60\n\
INI"

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
