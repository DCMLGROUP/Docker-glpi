FROM debian:12
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    apache2 \
    php libapache2-mod-php \
    php-xml php-curl php-gd php-intl php-mbstring php-zip php-ldap php-imap \
    ca-certificates curl jq tar \
 && rm -rf /var/lib/apt/lists/*

# Télécharger la dernière release GLPI et la déployer en racine (sans sous-dossier)
WORKDIR /tmp
RUN set -eux; \
    TAG="$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | jq -r '.tag_name')" ; \
    curl -fsSL -o glpi.tgz "https://github.com/glpi-project/glpi/releases/download/${TAG}/glpi-${TAG}.tgz" ; \
    tar -xzf glpi.tgz ; rm glpi.tgz ; \
    rm -rf /var/www/html/* ; mv glpi/* /var/www/html/ ; rmdir glpi

# Apache : DocumentRoot = /public + Alias /install
RUN sed -i 's/^Listen .*/Listen 0.0.0.0:80/' /etc/apache2/ports.conf \
 && a2enmod rewrite headers \
 && printf '%s\n' \
   '<VirtualHost *:80>' \
   '  DocumentRoot /var/www/html/public' \
   '' \
   '  # GLPI 11: /install est en dehors de /public, on l’expose via un Alias' \
   '  Alias /install /var/www/html/install' \
   '  <Directory /var/www/html/install>' \
   '    Require all granted' \
   '    AllowOverride All' \
   '  </Directory>' \
   '' \
   '  <Directory /var/www/html/public>' \
   '    AllowOverride All' \
   '    Require all granted' \
   '    DirectoryIndex index.php' \
   '  </Directory>' \
   '' \
   '  ErrorLog ${APACHE_LOG_DIR}/error.log' \
   '  CustomLog ${APACHE_LOG_DIR}/access.log combined' \
   '</VirtualHost>' \
   > /etc/apache2/sites-available/000-default.conf \
 && chown -R www-data:www-data /var/www/html

EXPOSE 80
CMD ["apachectl","-D","FOREGROUND"]