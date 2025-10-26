# Image de base
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Mise à jour + paquets (Apache, MariaDB, PHP 8.3, utilitaires, cron)
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y \
      apache2 mariadb-server mariadb-client wget tar unzip cron \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd \
      php-ldap php-intl php-mbstring php-zip php-imap \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache \
      libsodium23 && \
    rm -rf /var/lib/apt/lists/*

# Télécharger GLPI
WORKDIR /tmp
RUN wget https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz

# Déployer GLPI dans /var/www/html
RUN mkdir -p /var/www/html \
 && tar -xzf /tmp/glpi-11.0.1.tgz -C /var/www/html --strip-components=1 \
 && rm -f /tmp/glpi-11.0.1.tgz

# Apache: vhost /public + rewrite (vhost, pas .htaccess)
RUN a2enmod rewrite && rm -f /etc/apache2/sites-enabled/000-default.conf
RUN cat > /etc/apache2/sites-available/glpi.conf <<'EOF'
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

# Réglages PHP recommandés
RUN mkdir -p /etc/php/8.3/apache2/conf.d && \
    cat > /etc/php/8.3/apache2/conf.d/90-glpi.ini <<'INI'
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

# Droits nécessaires (files, config, marketplace)
RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
      chown -R www-data:www-data "$d"; \
      find "$d" -type d -exec chmod 775 {} \; ; \
      find "$d" -type f -exec chmod 664 {} \; ; \
    done

# Permissions de base
RUN chown -R www-data:www-data /var/www/html && \
    find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# Variables d'environnement (pilotage post-install)
ENV GLPI_LANG=fr_FR \
    GLPI_PLUGINS="" \
    GLPI_ADMIN_PASS="" \
    GLPI_TIMEZONE_DB_IMPORT=1

# Script d'init complet (DB + GLPI + timezones + cron + plugins)
RUN printf '%s\n' \
'#!/usr/bin/env bash' \
'set -euo pipefail' \
'' \
'echo "[start] bootstrapping MariaDB..."' \
'service mariadb start' \
'sleep 5' \
'' \
'# 1) S’assurer que la base et l’utilisateur existent (idempotent)' \
'mysql -uroot -e "ALTER USER '\''root'\''@'\''localhost'\'' IDENTIFIED BY '\''P@ssw0rd'\''; FLUSH PRIVILEGES;" || true' \
'mysql -uroot -pP@ssw0rd -e "CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"' \
'mysql -uroot -pP@ssw0rd -e "CREATE USER IF NOT EXISTS '\''glpi'\''@'\''localhost'\'' IDENTIFIED BY '\''P@ssw0rd'\'';"' \
'mysql -uroot -pP@ssw0rd -e "GRANT ALL PRIVILEGES ON glpi.* TO '\''glpi'\''@'\''localhost'\''; FLUSH PRIVILEGES;"' \
'' \
'cd /var/www/html' \
'' \
'# 2) Configuration DB GLPI + installation schéma si non fait' \
'if [ ! -f config/config_db.php ]; then' \
'  echo "[glpi] db:configure"' \
'  runuser -u www-data -- php bin/console db:configure \\' \
'    --db-host=127.0.0.1 --db-name=glpi --db-user=glpi --db-password=P@ssw0rd --reconfigure' \
'  echo "[glpi] db:install"' \
'  runuser -u www-data -- php bin/console db:install --default-language=${GLPI_LANG} --force --no-interaction' \
'fi' \
'' \
'# 3) Timezones (optionnel) : import zoneinfo MySQL + droits + activation GLPI' \
'if [ "${GLPI_TIMEZONE_DB_IMPORT:-1}" = "1" ]; then' \
'  echo "[tz] checking mysql.time_zone_name..."' \
'  if ! mysql -uroot -pP@ssw0rd -e "SELECT COUNT(*) FROM mysql.time_zone_name" >/dev/null 2>&1; then' \
'    echo "[tz] importing system zoneinfo into MySQL"' \
'    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot -pP@ssw0rd -D mysql' \
'  fi' \
'  echo "[tz] granting SELECT on mysql.time_zone_name to glpi@localhost"' \
'  mysql -uroot -pP@ssw0rd -e "GRANT SELECT ON mysql.time_zone_name TO '\''glpi'\''@'\''localhost'\''; FLUSH PRIVILEGES;"' \
'  echo "[tz] enabling timezones in GLPI"' \
'  runuser -u www-data -- php bin/console glpi:database:enable_timezones || true' \
'  runuser -u www-data -- php bin/console glpi:migration:timestamps || true' \
'fi' \
'' \
'# 4) Plugins (liste séparée par des virgules dans GLPI_PLUGINS)' \
'if [ -n "${GLPI_PLUGINS}" ]; then' \
'  IFS=\",\" read -ra PLUGS <<< "${GLPI_PLUGINS}";' \
'  for p in "${PLUGS[@]}"; do' \
'    if [ -d "plugins/$p" ]; then' \
'      echo "[plugin] installing/activating $p"' \
'      runuser -u www-data -- php bin/console glpi:plugin:install "$p" --no-interaction || true' \
'      runuser -u www-data -- php bin/console glpi:plugin:activate "$p" --no-interaction || true' \
'    else' \
'      echo "[plugin] skipped $p (plugins/$p absent)"' \
'    fi' \
'  done' \
'fi' \
'' \
'# 5) Mot de passe du compte super-admin glpi (optionnel)' \
'if [ -n "${GLPI_ADMIN_PASS}" ]; then' \
'  echo "[glpi] resetting admin password (user: glpi)"' \
'  runuser -u www-data -- php bin/console user:reset_password -p "${GLPI_ADMIN_PASS}" glpi || true' \
'fi' \
'' \
'# 6) Cron GLPI en mode CLI (toutes les minutes)' \
'echo "[cron] installing crontab for www-data (glpi:cron every minute)"' \
'echo "* * * * * www-data cd /var/www/html && /usr/bin/php bin/console glpi:cron > /proc/1/fd/1 2>&1" > /etc/cron.d/glpi' \
'chmod 0644 /etc/cron.d/glpi' \
'service cron start' \
'' \
'echo "[apache] starting httpd in foreground"' \
'exec apache2ctl -D FOREGROUND' \
> /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/start.sh"]
