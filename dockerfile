FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive \
    GLPI_BASE=/var/www/gtms/glpi

# Apache, PHP et outils pour récupérer la dernière release
RUN apt-get update && apt-get install -y --no-install-recommends \
    apache2 \
    php libapache2-mod-php \
    php-xml php-curl php-gd php-intl php-mbstring php-zip php-ldap php-imap \
    ca-certificates curl jq tar \
 && rm -rf /var/lib/apt/lists/*

# Télécharger la dernière version GLPI et l’installer dans /var/www/gtms/glpi
WORKDIR /tmp
RUN set -eux; \
    TAG="$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | jq -r '.tag_name')" ; \
    curl -fsSL -o glpi.tgz "https://github.com/glpi-project/glpi/releases/download/${TAG}/glpi-${TAG}.tgz" ; \
    tar -xzf glpi.tgz ; rm glpi.tgz ; \
    mkdir -p /var/www/gtms ; \
    rm -rf "${GLPI_BASE}" ; \
    mv glpi "${GLPI_BASE}"

# VHost Apache : DocumentRoot = /var/www/gtms/glpi/public + Alias /install
RUN sed -i 's/^Listen .*/Listen 0.0.0.0:80/' /etc/apache2/ports.conf \
 && a2enmod rewrite headers \
 && printf '%s\n' \
   '<VirtualHost *:80>' \
   '  ServerName _' \
   '  DocumentRoot /var/www/gtms/glpi/public' \
   '' \
   '  # Expose le programme d’installation hors de /public' \
   '  Alias /install /var/www/gtms/glpi/install' \
   '  <Directory /var/www/gtms/glpi/install>' \
   '    Require all granted' \
   '    AllowOverride All' \
   '  </Directory>' \
   '' \
   '  <Directory /var/www/gtms/glpi/public>' \
   '    Require all granted' \
   '    AllowOverride All' \
   '    DirectoryIndex index.php' \
   '  </Directory>' \
   '' \
   '  ErrorLog ${APACHE_LOG_DIR}/error.log' \
   '  CustomLog ${APACHE_LOG_DIR}/access.log combined' \
   '</VirtualHost>' \
   > /etc/apache2/sites-available/000-default.conf \
 && chown -R www-data:www-data /var/www/gtms

EXPOSE 80
CMD ["apachectl","-D","FOREGROUND"]