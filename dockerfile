# ===============================
#  Dockerfile - GLPI 11.0.1 (Dokploy friendly)
# ===============================

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# ---- Packages ----
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates tar unzip \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd \
      php-ldap php-intl php-mbstring php-zip php-imap \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache libsodium23 \
      util-linux procps && \
    update-ca-certificates && rm -rf /var/lib/apt/lists/*

# ---- GLPI 11.0.1 ----
WORKDIR /tmp
RUN curl -fsSL -o glpi-11.0.1.tgz \
      https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz && \
    mkdir -p /var/www/html && \
    tar -xzf glpi-11.0.1.tgz -C /var/www/html --strip-components=1 && \
    rm -f glpi-11.0.1.tgz

# ---- Apache vhost (/public) ----
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

# ---- PHP tuning ----
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

# ---- GLPI permissions ----
RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
    done && \
    chown -R www-data:www-data /var/www/html && \
    find /var/www/html/files /var/www/html/config /var/www/html/marketplace -type d -exec chmod 775 {} \; && \
    find /var/www/html/files /var/www/html/config /var/www/html/marketplace -type f -exec chmod 664 {} \; && \
    find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# ---- Entrypoint: init MariaDB + install GLPI si besoin (non bloquant) ----
# Personnalisables à l’exécution:
#   - DB_PASSWORD (mot de passe SQL de l’utilisateur glpi)
#   - GLPI_ADMIN_PASSWORD (mot de passe admin GLPI)
ENV DB_PASSWORD="P@ssw0rd" \
    GLPI_ADMIN_PASSWORD="Admin123!"

RUN printf '%s\n' \
'#!/usr/bin/env bash' \
'set -euo pipefail' \
'' \
'# Répertoires runtime requis' \
'mkdir -p /run/mysqld /run/apache2' \
'chown -R mysql:mysql /run/mysqld /var/lib/mysql' \
'chown -R www-data:www-data /run/apache2 || true' \
'' \
'# Initialisation du datadir MariaDB au premier run' \
'if [ ! -d "/var/lib/mysql/mysql" ]; then' \
'  echo "[INIT] Initialisation du datadir MariaDB..."' \
'  mariadb-install-db --user=mysql --ldata=/var/lib/mysql >/dev/null' \
'fi' \
'' \
'# Démarrage MariaDB en arrière-plan' \
'echo "[INIT] Démarrage de MariaDB..."' \
'mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &' \
'' \
'# Tâche d’auto-install en arrière-plan pour ne pas bloquer Apache (évite 502)' \
'(' \
'  set +e' \
'  for i in $(seq 1 60); do' \
'    if mysqladmin ping -uroot --silent; then break; fi' \
'    sleep 1' \
'  done' \
'' \
'  # Création BDD/utilisateur (idempotent)' \
'  mysql -uroot <<SQL' \
'CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' \
'CREATE USER IF NOT EXISTS '"'"'glpi'"'"'@'"'"'localhost'"'"' IDENTIFIED BY "'"'"'${DB_PASSWORD}'"'"'";' \
'GRANT ALL PRIVILEGES ON glpi.* TO '"'"'glpi'"'"'@'"'"'localhost'"'"';' \
'FLUSH PRIVILEGES;' \
'SQL' \
'' \
'  # Charger les timezones (best-effort)' \
'  mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot mysql >/dev/null 2>&1 || true' \
'' \
'  # Installation GLPI si nécessaire' \
'  if [ ! -f /var/www/html/config/config_db.php ]; then' \
'    echo "[INIT] Installation silencieuse de GLPI..."' \
'    runuser -u www-data -- php /var/www/html/bin/console database:install \\' \
'      --db-host=127.0.0.1 \\' \
'      --db-name=glpi \\' \
'      --db-user=glpi \\' \
'      --db-password="${DB_PASSWORD}" \\' \
'      --admin-password="${GLPI_ADMIN_PASSWORD}" \\' \
'      --no-interaction --force || true' \
'    runuser -u www-data -- php /var/www/html/bin/console db:enable_timezones --no-interaction || true' \
'    chown -R www-data:www-data /var/www/html || true' \
'  fi' \
') &' \
'' \
'echo "[INIT] Lancement d’Apache (foreground)..."' \
'exec apache2ctl -D FOREGROUND' \
> /usr/local/bin/docker-entrypoint.sh && chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD curl -fsS http://127.0.0.1/ || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
