FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive \
    GLPI_VERSION=10.0.15 \
    GLPI_URL=https://github.com/glpi-project/glpi/releases/download \
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data

# Paquets
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget unzip \
      supervisor \
      apache2 \
      mariadb-server \
      php php-cli php-fpm php-mysql php-xml php-curl php-gd php-ldap php-imap php-intl php-mbstring php-zip php-apcu \
      && apt-get clean && rm -rf /var/lib/apt/lists/*

# Téléchargement GLPI
WORKDIR /var/www/html
RUN wget -O glpi.tgz "${GLPI_URL}/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz" \
    && tar -xzf glpi.tgz \
    && rm glpi.tgz \
    && mv glpi/* . \
    && rmdir glpi \
    && chown -R www-data:www-data /var/www/html

# Logs & data persistants
RUN mkdir -p /var/log/supervisor /docker-entrypoint-init.d \
    /var/lib/mysql \
    /var/www/html/files /var/www/html/config \
    && chown -R mysql:mysql /var/lib/mysql \
    && chown -R www-data:www-data /var/www/html/files /var/www/html/config

# Config supervisord
COPY supervisord.conf /etc/supervisor/supervisord.conf

# Script d'init (DB + droits)
COPY init-glpi.sh /usr/local/bin/init-glpi.sh
RUN chmod +x /usr/local/bin/init-glpi.sh

# Apache en foreground
RUN sed -i 's|^export APACHE_LOCK_DIR.*|export APACHE_LOCK_DIR=/var/lock/apache2|' /etc/apache2/envvars \
 && sed -i 's|^export APACHE_PID_FILE.*|export APACHE_PID_FILE=/var/run/apache2/apache2.pid|' /etc/apache2/envvars \
 && a2enmod rewrite

# Variables DB (sur lesquelles on peut agir avec -e)
ENV GLPI_DB_NAME=glpi \
    GLPI_DB_USER=glpi \
    GLPI_DB_PASSWORD=glpi \
    GLPI_DB_HOST=localhost

EXPOSE 80

# Volumes (persistance DB + fichiers GLPI)
VOLUME ["/var/lib/mysql", "/var/www/html/files", "/var/www/html/config"]

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]