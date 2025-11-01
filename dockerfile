# ===============================
#  Dockerfile - GLPI 11.0.1 Full Auto (PHP dans /var/www/html)
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

# ---- Apache vhost (root sur /public) ----
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
__VHOST__
RUN a2ensite glpi

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

# ---------- Script de démarrage (PHP DANS /var/www/html) ----------
RUN cat > /usr/local/bin/start-glpi.sh <<'__START__' && chmod +x /usr/local/bin/start-glpi.sh
#!/usr/bin/env bash
set -Eeuo pipefail
LOG=/var/log/glpi_install.log
exec > >(tee -a "$LOG") 2>&1

echo "==[BOOT]== $(date -Is) GLPI startup (PHP in /var/www/html)"

# Dossiers runtime
mkdir -p /run/mysqld /run/apache2 /var/www/html/config
chown -R mysql:mysql /run/mysqld /var/lib/mysql
chown -R www-data:www-data /run/apache2 || true

# (1) Écrire (toujours) config_db.php
cat >/var/www/html/config/config_db.php <<'__CFG__'
<?php
class DB extends DBmysql {
   public $dbhost = '127.0.0.1';
   public $dbuser = 'glpi';
   public $dbpassword = 'P@ssw0rd';
   public $dbdefault = 'glpi';
   public $use_utf8mb4 = true;
}
__CFG__
chown -R www-data:www-data /var/www/html/config
chmod 644 /var/www/html/config/config_db.php
echo "==[CONF]== config_db.php écrit"

# (2) Init MariaDB si nécessaire
if [ ! -d "/var/lib/mysql/mysql" ]; then
  echo "==[DB]== Initialisation datadir MariaDB"
  mariadb-install-db --user=mysql --ldata=/var/lib/mysql
fi

# (3) Démarrer MariaDB et tester
echo "==[DB]== Démarrage MariaDB"
mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &
for i in $(seq 1 90); do
  mysqladmin ping -uroot --silent && break || sleep 1
done
mysql -uroot -e "SELECT VERSION()\G" || { echo "!! MariaDB KO"; exit 1; }

# (4) BDD + user
mysql -uroot <<'__SQL__'
CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS "glpi"@"localhost" IDENTIFIED BY "P@ssw0rd";
GRANT ALL PRIVILEGES ON glpi.* TO "glpi"@"localhost";
FLUSH PRIVILEGES;
__SQL__
echo "==[DB]== BDD et utilisateur glpi OK"

# (5) Timezones MySQL
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot mysql >/dev/null 2>&1 || true

# IMPORTANT : exécuter toutes les commandes PHP DANS /var/www/html
cd /var/www/html

# (6) Installer GLPI si glpi_users n'existe pas
HAS_USERS=$(mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glpi' AND table_name='glpi_users';" -uroot || echo 0)
if [ "$HAS_USERS" -eq 0 ]; then
  echo "==[INSTALL]== CLI GLPI (dans /var/www/html)…"
  runuser -u www-data -- bash -lc 'cd /var/www/html && php -v && php bin/console --version'
  runuser -u www-data -- bash -lc 'cd /var/www/html && php bin/console database:install \
    --db-host=127.0.0.1 --db-name=glpi --db-user=glpi --db-password="P@ssw0rd" \
    --admin-password="P@ssw0rd" --no-interaction --force'

  # Vérif immédiate
  HAS_USERS=$(mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glpi' AND table_name='glpi_users';" -uroot || echo 0)
  if [ "$HAS_USERS" -eq 0 ]; then
    echo "!! Install CLI OK mais pas de tables. Voir $LOG et /var/log/mysqld_safe.log"
    exit 1
  fi

  # Timezones GLPI + reset MDP
  runuser -u www-data -- bash -lc 'cd /var/www/html && php bin/console db:enable_timezones --no-interaction || true'
  for u in glpi tech normal "post-only" postonly; do
    runuser -u www-data -- bash -lc "cd /var/www/html && php bin/console glpi:user:password-reset \"$u\" --password \"P@ssw0rd\" || true"
  done
  echo "==[INSTALL]== GLPI installé. Comptes défaut = P@ssw0rd"
else
  echo "==[INSTALL]== GLPI déjà installé (tables présentes)"
fi

# (7) Vérifier l'inclusion PHP (dans /var/www/html)
runuser -u www-data -- bash -lc 'cd /var/www/html && php -r "require \"inc/defines.php\"; require \"inc/based_config.php\"; require \"config/config_db.php\"; echo \"==[PHP]== include OK\n\";"' \
  || { echo "!! PHP include KO (config_db.php)"; exit 1; }

# (8) Lancer Apache
echo "==[WEB]== Démarrage Apache"
exec apache2ctl -D FOREGROUND
__START__

# ---- Exposition & santé ----
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD curl -fsS http://127.0.0.1/ || exit 1
ENTRYPOINT ["/usr/local/bin/start-glpi.sh"]
