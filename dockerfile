# Image de base
FROM ubuntu:24.04

RUN apt update && apt upgrade -y

RUN apt-get install -y apache2 mariadb-server wget tar unzip \
    php libapache2-mod-php php-mysql php-xml php-curl php-gd \
    php-ldap php-intl php-mbstring php-zip php-imap

# Télécharger l'archive dans /tmp
WORKDIR /tmp
RUN wget https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz

# Déployer GLPI proprement (sans strip-components)
RUN tar -xzf /tmp/glpi-11.0.1.tgz -C /tmp \
 && mv /tmp/glpi-*/* /var/www/html/ \
 && rm -rf /tmp/glpi-* /tmp/glpi-11.0.1.tgz

# Config Apache : vhost /public + rewrite + index.php + -MultiViews
RUN a2enmod rewrite && rm -f /etc/apache2/sites-enabled/000-default.conf

RUN cat > /etc/apache2/sites-available/glpi.conf <<'EOF'
<VirtualHost *:80>
    ServerName _

    DocumentRoot /var/www/html/public
    DirectoryIndex index.php

    <Directory /var/www/html/public>
        Options -MultiViews +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # (Optionnel) restreindre hors /public
    <Directory /var/www/html>
        Require all denied
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/glpi_error.log
    CustomLog ${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF

RUN a2ensite glpi

# Permissions simples
RUN chown -R www-data:www-data /var/www/html \
 && find /var/www/html -type d -exec chmod 755 {} \; \
 && find /var/www/html -type f -exec chmod 644 {} \;

EXPOSE 80
CMD ["apache2ctl","-D","FOREGROUND"]
