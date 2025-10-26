# Image de base
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt upgrade -y

# Apache + PHP + dépendances GLPI
RUN apt-get install -y apache2 mariadb-server wget tar unzip \
    php libapache2-mod-php php-mysql php-xml php-curl php-gd \
    php-ldap php-intl php-mbstring php-zip php-imap

# Télécharger GLPI
WORKDIR /tmp
RUN wget https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz

# Déployer GLPI dans /var/www/html/public
RUN mkdir -p /var/www/html \
 && tar -xzf /tmp/glpi-11.0.1.tgz -C /var/www/html --strip-components=1 \
 && rm -f /tmp/glpi-11.0.1.tgz

# Activer modules Apache et créer vhost
RUN a2enmod rewrite && rm -f /etc/apache2/sites-enabled/000-default.conf
RUN cat > /etc/apache2/sites-available/glpi.conf <<'EOF'
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

# Extensions PHP requises GLPI (bcmath, bz2, exif, sodium, opcache)
RUN set -eux; \
    PHPV="$(php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;')"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "php${PHPV}-bcmath" \
        "php${PHPV}-bz2" \
        "php${PHPV}-exif" \
        "php${PHPV}-sodium" \
        "php${PHPV}-opcache"; \
    rm -rf /var/lib/apt/lists/*

# Ajustements PHP recommandés GLPI
RUN set -eux; \
    PHPV="$(php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;')"; \
    CONF_DIR="/etc/php/${PHPV}/apache2/conf.d"; \
    mkdir -p "$CONF_DIR"; \
    cat > "$CONF_DIR/90-glpi.ini" <<'INI'
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

# Droits à écrire (GLPI)
RUN for d in /var/www/html/files /var/www/html/config /var/www/html/marketplace; do \
      mkdir -p "$d"; \
      chown -R www-data:www-data "$d"; \
      find "$d" -type d -exec chmod 775 {} \; ; \
      find "$d" -type f -exec chmod 664 {} \; ; \
    done

# Permissions de base pour le reste (sécurisé)
RUN chown -R www-data:www-data /var/www/html \
 && find /var/www/html -type d -exec chmod 755 {} \; \
 && find /var/www/html -type f -exec chmod 644 {} \;

EXPOSE 80
CMD ["apache2ctl","-D","FOREGROUND"]
