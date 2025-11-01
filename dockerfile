# ---- Entrypoint: init MariaDB + install GLPI si besoin (non bloquant) ----
ENV DB_PASSWORD="P@ssw0rd" \
    GLPI_ADMIN_PASSWORD="Admin123!"

RUN printf '%s\n' \
'#!/usr/bin/env bash' \
'set -euo pipefail' \
'' \
'# Répertoires runtime' \
'mkdir -p /run/mysqld /run/apache2' \
'chown -R mysql:mysql /run/mysqld /var/lib/mysql' \
'chown -R www-data:www-data /run/apache2 || true' \
'' \
'# Init datadir MariaDB au premier run' \
'if [ ! -d "/var/lib/mysql/mysql" ]; then' \
'  echo "[INIT] Initialisation du datadir MariaDB..."' \
'  mariadb-install-db --user=mysql --ldata=/var/lib/mysql >/dev/null' \
'fi' \
'' \
'# Démarre MariaDB en arrière-plan' \
'echo "[INIT] Démarrage de MariaDB..."' \
'mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &' \
'' \
'# Tâche d’auto-install en arrière-plan (pour ne pas bloquer Apache/proxy)' \
'(' \
'  set +e' \
'  # Attendre que MariaDB réponde' \
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
'  # Installer GLPI si pas déjà fait' \
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
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
