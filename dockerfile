# ===============================
#  Dockerfile - GLPI 11.0.1 Full Auto (no ENV, install bloquante + logs)
# ===============================

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates tar unzip \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd \
      php-ldap php-intl php-mbstring php-zip php-imap \
      php8.3-bcmath php8.3-bz2 php8.3-exif php8.3-opcache libsodium23 \
      util-linux procps && \
    update-ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN wget -q https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz && \
    mkdir -p /var/www/html && \
    tar -xzf glpi-11.0.1.tgz -C /var/www/html --strip-components=1 && \
    rm -f glpi-11.0.1.tgz

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

RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
    done && \
    chown -R www-data:www-data /var/www/html && \
    find /var/www/html -type d -exec chmod 755 {} \; && \
    find /var/www/html -type f -exec chmod 644 {} \;

# ---------- Script de démarrage : installe GLPI avant Apache (logs détaillés) ----------
RUN cat > /usr/local/bin/start-glpi.sh <<'BASH' && chmod +x /usr/local/bin/start-glpi.sh
#!/usr/bin/env bash
set -Eeuo pipefail

LOG=/var/log/glpi_install.log
exec > >(tee -a "$LOG") 2>&1

echo "==[BOOT]== $(date -Is) GLPI full auto startup"

mkdir -p /run/mysqld /run/apache2 /var/www/html/config
chown -R mysql:mysql /run/mysqld /var/lib/mysql
chown -R www-data:www-data /run/apache2 || true

# (1) Toujours réécrire config_db.php (au cas où un volume vide écrase /config)
cat >/var/www/html/config/config_db.php <<'PHP'
<?php
class DB extends DBmysql {
   public $dbhost = '127.0.0.1';
   public $dbuser = 'glpi';
   public $dbpassword = 'P@ssw0rd';
   public $dbdefault = 'glpi';
   public $use_utf8mb4 = true;
}
PHP
chown -R www-data:www-data /var/www/html/config
chmod 644 /var/www/html/config/config_db.php
echo "==[CONF]== config_db.php écrit"

# (2) Init MariaDB si nécessaire
if [ ! -d "/var/lib/mysql/mysql" ]; then
  echo "==[DB]== Initialisation datadir MariaDB"
  mariadb-install-db --user=mysql --ldata=/var/lib/mysql
fi

echo "==[DB]== Démarrage MariaDB"
mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &
for i in $(seq 1 90); do
  if mysqladmin ping -uroot --silent; then break; fi
  sleep 1
done
mysql -uroot -e "SELECT VERSION()\G" || { echo "!! MariaDB KO"; exit 1; }

# (3) Créer BDD + user (idempotent)
mysql -uroot <<'SQL'
CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS "glpi"@"localhost" IDENTIFIED BY "P@ssw0rd";
GRANT ALL PRIVILEGES ON glpi.* TO "glpi"@"localhost";
FLUSH PRIVILEGES;
SQL
echo "==[DB]== BDD et utilisateur glpi OK"

# (4) Charger les timezones (best-effort)
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot mysql >/dev/null 2>&1 || true

# (5) Vérifier si la table glpi_users existe déjà
HAS_USERS=$(mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glpi' AND table_name='glpi_users';" -uroot || echo 0)

# (6) Installer GLPI en AVANT-PLAN si nécessaire (ou forcer au premier run)
if [ "$HAS_USERS" -eq 0 ]; then
  echo "==[INSTALL]== Lancement install CLI GLPI (peut prendre quelques secondes)..."
  sudo -u www-data php /var/www/html/bin/console database:install \
    --db-host=127.0.0.1 \
    --db-name=glpi \
    --db-user=glpi \
    --db-password="P@ssw0rd" \
    --admin-password="P@ssw0rd" \
    --no-interaction --force

  # Double check
  HAS_USERS=$(mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glpi' AND table_name='glpi_users';" -uroot || echo 0)
  if [ "$HAS_USERS" -eq 0 ]; then
    echo "!! Install CLI terminée mais aucune table détectée. Voir $LOG et /var/log/mysqld_safe.log"
    exit 1
  fi

  # Timezones GLPI
  sudo -u www-data php /var/www/html/bin/console db:enable_timezones --no-interaction || true

  # Reset des mots de passe des comptes par défaut
  for u in glpi tech normal "post-only" postonly; do
    sudo -u www-data php /var/www/html/bin/console glpi:user:password-reset "$u" --password "P@ssw0rd" || true
  done
  echo "==[INSTALL]== GLPI installé. Comptes défaut = P@ssw0rd"
else
  echo "==[INSTALL]== GLPI déjà installé (tables présentes)"
fi

# (7) Vérifier que PHP peut lire la conf
php -r 'require "/var/www/html/inc/defines.php"; require "/var/www/html/inc/based_config.php"; require "/var/www/html/config/config_db.php"; echo "==[PHP]== include OK\n";' || { echo "!! PHP include KO (config_db.php)"; exit 1; }

# (8) Lancer Apache en foreground
echo "==[WEB]== Démarrage Apache"
exec apache2ctl -D FOREGROUND
BASH

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD curl -fsS http://127.0.0.1/ || exit 1
ENTRYPOINT ["/usr/local/bin/start-glpi.sh"]
