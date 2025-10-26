FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive \
    GLPI_VERSION=10.0.15 \
    GLPI_DB_NAME=glpi \
    GLPI_DB_USER=glpi \
    GLPI_DB_PASSWORD=glpi

# Mise à jour + dépendances
RUN apt-get update && \
    apt-get install -y apache2 wget tar mariadb-server \
    php php-mysql php-cli php-xml php-curl php-gd php-mbstring php-zip php-intl php-apcu && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Installer GLPI
WORKDIR /var/www/html
RUN wget https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz && \
    tar -xzf glpi-${GLPI_VERSION}.tgz && \
    rm glpi-${GLPI_VERSION}.tgz && \
    mv glpi/* . && rmdir glpi && \
    chown -R www-data:www-data /var/www/html

# Config MySQL
RUN service mariadb start && \
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${GLPI_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" && \
    mysql -e "CREATE USER IF NOT EXISTS '${GLPI_DB_USER}'@'localhost' IDENTIFIED BY '${GLPI_DB_PASSWORD}';" && \
    mysql -e "GRANT ALL ON \`${GLPI_DB_NAME}\`.* TO '${GLPI_DB_USER}'@'localhost';" && \
    mysql -e "FLUSH PRIVILEGES;"

# Apache en foreground
RUN echo "ServerName localhost" >> /etc/apache2/apache2.conf

EXPOSE 80

CMD service mariadb start && apachectl -D FOREGROUND