# GLPI + MariaDB dans un seul conteneur, sans /glpi dans l'URL
FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive \
    GLPI_VERSION=10.0.15 \
    GLPI_DB_NAME=glpi \
    GLPI_DB_USER=glpi \
    GLPI_DB_PASSWORD=glpi

# Paquets
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget tar unzip \
      supervisor \
      apache2 \
      mariadb-server \
      php php-cli php-mysql php-xml php-curl php-gd php-ldap php-imap php-intl php-mbstring php-zip php-apcu \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Téléchargement et installation GLPI à la racine du vhost
WORKDIR /var/www/html
RUN wget -O glpi.tgz https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz \
  && tar -xzf glpi.tgz \
  && rm glpi.tgz \
  && mv glpi/* . \
  && rmdir glpi \
  && chown -R www-data:www-data /var/www/html

# Apache : écouter sur toutes interfaces + GLPI à la racine + rewrite
RUN sed -i 's/^Listen .*/Listen 0.0.0.0:80/' /etc/apache2/ports.conf \
  && a2enmod rewrite headers \
  && printf '%s\n' \
     '<VirtualHost *:80>' \
     '  DocumentRoot /var/www/html' \
     '  <Directory /var/www/html>' \
     '    AllowOverride All' \
     '    Require all granted' \
     '  </Directory>' \
     '  ErrorLog ${APACHE_LOG_DIR}/error.log' \
     '  CustomLog ${APACHE_LOG_DIR}/access.log combined' \
     '</VirtualHost>' \
     > /etc/apache2/sites-available/000-default.conf \
  && printf 'DirectoryIndex index.php index.html\n' > /var/www/html/.htaccess

# Script d'init (création DB au premier démarrage) — intégré depuis le Dockerfile
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'echo ">> Attente de MariaDB..."' \
  'for i in {1..60}; do' \
  '  if mysqladmin ping --silent; then break; fi' \
  '  sleep 1' \
  'done' \
  'if mysql -e "USE \`'"${GLPI_DB_NAME}"'\`" >/dev/null 2>&1; then' \
  '  echo ">> Base déjà présente, init ignoré."' \
  '  exit 0' \
  'fi' \
  'echo ">> Initialisation de la base GLPI..."' \
  'mysql -e "CREATE DATABASE IF NOT EXISTS \`'"${GLPI_DB_NAME}"'\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"' \
  'mysql -e "CREATE USER IF NOT EXISTS \x27'"${GLPI_DB_USER}"'\x27@\x27localhost\x27 IDENTIFIED BY \x27'"${GLPI_DB_PASSWORD}"'\x27;"' \
  'mysql -e "GRANT ALL PRIVILEGES ON \`'"${GLPI_DB_NAME}"'\`.* TO \x27'"${GLPI_DB_USER}"'\x27@\x27localhost\x27;"' \
  'mysql -e "FLUSH PRIVILEGES;"' \
  'chown -R www-data:www-data /var/www/html' \
  'echo ">> Init GLPI terminé."' \
  > /usr/local/bin/init-glpi.sh \
  && chmod +x /usr/local/bin/init-glpi.sh

# Supervisor inline (toujours un seul fichier)
RUN mkdir -p /var/log/supervisor
RUN printf '%s\n' \
  '[supervisord]' \
  'nodaemon=true' \
  '' \
  '[program:mariadb]' \
  'command=/usr/sbin/mysqld' \
  'user=mysql' \
  'autostart=true' \
  'autorestart=true' \
  'priority=10' \
  '' \
  '[program:init-glpi]' \
  'command=/usr/local/bin/init-glpi.sh' \
  'user=root' \
  'autostart=true' \
  'autorestart=false' \
  'startretries=10' \
  'priority=20' \
  '' \
  '[program:apache2]' \
  'command=/usr/sbin/apachectl -D FOREGROUND' \
  'user=root' \
  'autostart=true' \
  'autorestart=true' \
  'priority=30' \
  > /etc/supervisor/conf.d/glpi.conf

EXPOSE 80

# Volumes (optionnel — persistance)
VOLUME ["/var/lib/mysql", "/var/www/html/files", "/var/www/html/config"]

CMD ["/usr/bin/supervisord","-c","/etc/supervisor/conf.d/glpi.conf"]