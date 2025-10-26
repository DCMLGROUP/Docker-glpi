# Image de base
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    APACHE_LOG_DIR=/var/log/apache2 \
    TZ=Europe/Paris

ARG GLPI_VERSION=10.0.15

# Installation Apache / PHP / MariaDB
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates wget curl unzip tzdata supervisor \
    apache2 libapache2-mod-php \
    php php-cli php-mysql php-xml php-curl php-gd php-ldap php-imap php-intl php-mbstring php-zip php-bcmath php-apcu \
    mariadb-server && \
    rm -rf /var/lib/apt/lists/*

# Téléchargement GLPI
WORKDIR /var/www
RUN wget -q https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz && \
    tar -xzf glpi-${GLPI_VERSION}.tgz && \
    rm -f glpi-${GLPI_VERSION}.tgz && \
    mv glpi glpi-${GLPI_VERSION} && \
    ln -s /var/www/glpi-${GLPI_VERSION} /var/www/html && \
    chown -R www-data:www-data /var/www

# Configuration Apache (rewrite pour GLPI)
RUN a2enmod rewrite && \
    echo "<VirtualHost *:80> \
        DocumentRoot /var/www/html/public \
        <Directory /var/www/html/public> \
            AllowOverride All \
            Require all granted \
        </Directory> \
    </VirtualHost>" > /etc/apache2/sites-available/000-default.conf && \
    chown -R www-data:www-data /var/www/html

# Création DB GLPI
RUN service mariadb start && \
    mariadb -e "CREATE DATABASE IF NOT EXISTS glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" && \
    mariadb -e "CREATE USER IF NOT EXISTS 'glpi'@'localhost' IDENTIFIED BY 'glpi';" && \
    mariadb -e "GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'localhost'; FLUSH PRIVILEGES;"

# Script de démarrage
CMD service mariadb start && apachectl -D FOREGROUND

EXPOSE 80