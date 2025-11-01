# ===============================
#  Dockerfile - GLPI 11.0.1 (sans post-install)
#  Ubuntu 24.04 + Apache2 + PHP 8.3 (+ MariaDB local optionnelle)
# ===============================

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# ---- Paquets système, Apache, MariaDB, PHP ----
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates tar unzip \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd \
      php-ldap php-intl php-mbstring php-zip php-imap \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache libsodium23 \
      util-linux procps sudo && \
    update-ca-certificates && rm -rf /var/lib/apt/lists/*

# ---- Déploiement GLPI 11.0.1 ----
WORKDIR /tmp
RUN wget -q https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz && \
    mkdir -p /var/www/html && \
    tar -xzf glpi-11.0.1.tgz -C /var/www/html --strip-components=1 && \
    rm -f glpi-11.0.1.tgz

# ---- Apache vhost (DocumentRoot sur /public) ----
RUN a2enmod rewrite && rm -f /etc/apache2/sites-enabled/000-default.conf && \
    cat >/etc/apache2/sites-available/glpi.conf <<'__VHOST__'
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
__VHOST__ && \
    a2ensite glpi

# ---- PHP tuning ----
RUN mkdir -p /etc/php/8.3/apache2/conf.d && \
    cat >/etc/php/8.3/apache2/conf.d/90-glpi.ini <<'__PHPINI__'
memory_limit = 512M
session.use_strict_mode = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
__PHPINI__

# ---- Permissions web ----
RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
    done && \
    chown -R www-data:www-data /var/www/html && \
    find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# ---------- Script d'entrée (sans post-install) ----------
# - Initialise MariaDB si le datadir est vide
# - Démarre MariaDB en arrière-plan (optionnel)
# - (Optionnel) crée la base 'glpi' et l'utilisateur 'glpi' sans toucher à GLPI
# - Lance Apache au premier plan (OK pour Dokploy)
RUN cat > /usr/local/bin/entrypoint.sh <<'__ENTRY__' && chmod +x /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -Eeuo pipefail

echo "==[BOOT]== $(date -Is) GLPI container (no post-install)"

# Prépare les répertoires runtime
mkdir -p /run/mysqld /run/apache2
chown -R mysql:mysql /run/mysqld /var/lib/mysql || true

# (A) MariaDB local optionnelle
if command -v mariadb-install-db >/dev/null 2>&1; then
  if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "==[DB]== Initialisation de MariaDB (datadir vide)"
    mariadb-install-db --user=mysql --ldata=/var/lib/mysql
  fi

  echo "==[DB]== Démarrage MariaDB"
  mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &
  for i in $(seq 1 60); do
    mysqladmin ping -uroot --silent && break || sleep 1
  done

  # (B) Création OPTIONNELLE de la base et de l'utilisateur (SANS post-install GLPI)
  if mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
    mysql -uroot <<'__SQL__'
CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'glpi'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'localhost';
FLUSH PRIVILEGES;
__SQL__
    echo "==[DB]== Base 'glpi' et user 'glpi' prêts (aucune post-install GLPI exécutée)"
  fi
else
  echo "==[DB]== MariaDB non présent, on continue sans base locale"
fi

# (C) Démarrage Apache au premier plan (Dokploy OK)
echo "==[WEB]== Démarrage Apache (foreground)"
exec apache2ctl -D FOREGROUND
__ENTRY__

# ---- Exposition & santé ----
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD curl -fsS http://127.0.0.1/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
