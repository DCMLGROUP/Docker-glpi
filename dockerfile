# + cron pour les actions planifiées GLPI
RUN apt-get update && apt-get install -y cron && rm -rf /var/lib/apt/lists/*

# Variables d'environnement pilotant le post-install
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
'# 1) S\'assurer que la base et l\'utilisateur existent (idempotent)' \
'mysql -uroot -e "ALTER USER '\''root'\''@'\''localhost'\'' IDENTIFIED BY '\''P@ssw0rd'\''; FLUSH PRIVILEGES;" || true' \
'mysql -uroot -pP@ssw0rd -e "CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"' \
'mysql -uroot -pP@ssw0rd -e "CREATE USER IF NOT EXISTS '\''glpi'\''@'\''localhost'\'' IDENTIFIED BY '\''P@ssw0rd'\'';"' \
'mysql -uroot -pP@ssw0rd -e "GRANT ALL PRIVILEGES ON glpi.* TO '\''glpi'\''@'\''localhost'\''; FLUSH PRIVILEGES;"' \
'' \
'cd /var/www/html' \
'' \
'# 2) Configuration DB GLPI (idempotent) + installation schéma si non fait' \
'if [ ! -f config/config_db.php ]; then' \
'  echo "[glpi] db:configure";' \
'  sudo -u www-data php bin/console db:configure \\' \
'    --db-host=127.0.0.1 --db-name=glpi --db-user=glpi --db-password=P@ssw0rd --reconfigure' \
'  echo "[glpi] db:install";' \
'  sudo -u www-data php bin/console db:install --default-language=${GLPI_LANG} --force --no-interaction' \
'fi' \
'' \
'# 3) Timezones (optionnel) : importe tables MySQL + droits + active côté GLPI' \
'if [ "${GLPI_TIMEZONE_DB_IMPORT:-1}" = "1" ]; then' \
'  echo "[tz] importing system zoneinfo into MySQL if needed";' \
'  mysql -uroot -pP@ssw0rd -e "SELECT COUNT(*) FROM mysql.time_zone_name" >/dev/null 2>&1 || \\' \
'    (mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -uroot -pP@ssw0rd -D mysql);' \
'  echo "[tz] granting SELECT on mysql.time_zone_name to glpi@localhost";' \
'  mysql -uroot -pP@ssw0rd -e "GRANT SELECT ON mysql.time_zone_name TO '\''glpi'\''@'\''localhost'\''; FLUSH PRIVILEGES;"' \
'  echo "[tz] enabling timezones in GLPI";' \
'  sudo -u www-data php bin/console glpi:database:enable_timezones || true' \
'  # Si GLPI demande une migration des champs datetime -> timestamp' \
'  sudo -u www-data php bin/console glpi:migration:timestamps || true' \
'fi' \
'' \
'# 4) Plugins (liste séparée par des virgules dans GLPI_PLUGINS)' \
'if [ -n "${GLPI_PLUGINS}" ]; then' \
'  IFS=\",\" read -ra PLUGS <<< "${GLPI_PLUGINS}";' \
'  for p in "${PLUGS[@]}"; do' \
'    if [ -d "plugins/$p" ]; then' \
'      echo "[plugin] installing/activating $p";' \
'      sudo -u www-data php bin/console glpi:plugin:install "$p" --no-interaction || true' \
'      sudo -u www-data php bin/console glpi:plugin:activate "$p" --no-interaction || true' \
'    else' \
'      echo "[plugin] skipped $p (plugins/$p absent)";' \
'    fi' \
'  done' \
'fi' \
'' \
'# 5) Mot de passe du compte super-admin glpi (optionnel)' \
'if [ -n "${GLPI_ADMIN_PASS}" ]; then' \
'  echo "[glpi] resetting admin password (user: glpi)";' \
'  sudo -u www-data php bin/console user:reset_password -p "${GLPI_ADMIN_PASS}" glpi || true' \
'fi' \
'' \
'# 6) Cron GLPI en mode CLI (toutes les minutes)' \
'echo "[cron] installing crontab for www-data (glpi:cron every minute)"' \
'echo "* * * * * www-data cd /var/www/html && /usr/bin/php bin/console glpi:cron > /proc/1/fd/1 2>&1" > /etc/cron.d/glpi' \
'chmod 0644 /etc/cron.d/glpi && crontab -u www-data -l >/dev/null 2>&1 || true' \
'service cron start' \
'' \
'echo "[apache] starting httpd in foreground"' \
'exec apache2ctl -D FOREGROUND' \
> /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

# On garde votre ENTRYPOINT et CMD
ENTRYPOINT ["/usr/local/bin/start.sh"]
