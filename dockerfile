# ===============================
#  Dockerfile - GLPI 11.0.1 Full Auto (no ENV)
# ===============================

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# ---- Installation des paquets ----
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates tar unzip \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd \
      php-ldap php-intl php-mbstring php-zip php-imap \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache libsodium23 \
      util-linux procps && \
    update-ca-certificates && rm -rf /var/lib/apt/lists/*

# ---- Téléchargement de GLPI ----
WORKDIR /tmp
RUN wget -q https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz && \
    mkdir -p /var/www/html && \
    tar -xzf glpi-11.0.1.tgz -C /var/www/html --strip-components=1 && \
    rm -f glpi-11.0.1.tgz

# ---- Configuration Apache ----
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

# ---- Configuration PHP ----
RUN mkdir -p /etc/php/8.3/apache2/conf.d && \
    cat >/etc/php/8.3/apache2/conf.d/90-glpi.ini <<'INI'
memory_limit = 512M
session.use_strict_mode = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
INI

# ---- Permissions ----
RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
    done && \
    chown -R www-data:www-data /var/www/html && \
    find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# ---- Pré-création du fichier de configuration ----
RUN cat >/var/www/html/config/config_db.php <<'PHP'
<?php
class DB extends DBmysql {
   public $dbhost = '127.0.0.1';
   public $dbuser = 'glpi';
   public $dbpassword = 'P@ssw0rd';
   public $dbdefault = 'glpi';
}
PHP
RUN chown -R www-data:www-data /var/www/html/config

# ---- Script de démarrage complet ----
RUN cat > /usr/local/bin/start-glpi.sh <<'BASH' && chmod +x /usr/local/bin/start-glpi.sh
#!/usr/bin/env bash
set -euo pipefail

echo "[BOOT] Lancement initial GLPI full auto..."
mkdir -p /run/mysqld /run/apache2
chown -R mysql:mysql /run/mysqld /var/lib/mysql
chown -R www-data:www-data /run/apache2 || true

# Initialiser MariaDB au premier run
if [ ! -d "/var/lib/mysql/mysql" ]; then
  echo "[INIT] Création du datadir MariaDB..."
  mariadb-install-db --user=mysql --ldata=/var/lib/mysql >/dev/null
fi

echo "[INIT] Démarrage de MariaDB..."
mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &
for i in $(seq 1 60); do
  mysqladmin ping -uroot --silent && break || sleep 1
done

echo "[INIT] Configuration de la base de données GLPI..."
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS "glpi"@"localhost" IDENTIFIED BY "P@ssw0rd";
GRANT ALL PRIVILEGES ON glpi.* TO "glpi"@"localhost";
FLUSH PRIVILEGES;
SQL

# Charger les timezones (best-effort)
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot mysql >/dev/null 2>&1 || true

# Vérifier si les tables GLPI existent déjà
NEED_INSTALL=$(mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glpi' AND table_name='glpi_users';" -uroot || echo 0)

if [ "$NEED_INSTALL" -eq 0 ]; then
  echo "[INSTALL] Installation GLPI silencieuse..."
  runuser -u www-data -- php /var/www/html/bin/console database:install \
    --db-host=127.0.0.1 \
    --db-name=glpi \
    --db-user=glpi \
    --db-password="P@ssw0rd" \
    --admin-password="P@ssw0rd" \
    --no-interaction --force

  runuser -u www-data -- php /var/www/html/bin/console db:enable_timezones --no-interaction || true

  # Réinitialiser les MDP des comptes par défaut à P@ssw0rd
  for u in glpi tech normal "post-only" postonly; do
    runuser -u www-data -- php /var/www/html/bin/console glpi:user:password-reset "$u" --password "P@ssw0rd" || true
  done

  echo "[INSTALL] Installation terminée. Comptes: glpi/tech/normal/post-only = P@ssw0rd"
else
  echo "[INSTALL] GLPI déjà installé."
fi

chown -R www-data:www-data /var/www/html
echo "[RUN] Lancement d’Apache..."
exec apache2ctl -D FOREGROUND
BASH

# ---- Ports et démarrage ----
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD curl -fsS http://127.0.0.1/ || exit 1
ENTRYPOINT ["/usr/local/bin/start-glpi.sh"]
