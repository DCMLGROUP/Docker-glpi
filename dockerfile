# Front-only GLPI (Apache + PHP), sans base de données
FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

# Paquets nécessaires (Apache, PHP, curl, jq pour récupérer la dernière version)
RUN apt-get update && apt-get install -y --no-install-recommends \
    apache2 \
    php libapache2-mod-php \
    php-xml php-curl php-gd php-intl php-mbstring php-zip \
    ca-certificates curl jq tar \
 && rm -rf /var/lib/apt/lists/*

# Récupération de la dernière version de GLPI depuis l'API GitHub
# Exemple: tag_name = "11.0.1" -> archive glpi-11.0.1.tgz
WORKDIR /tmp
RUN set -eux; \
    TAG="$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | jq -r '.tag_name')" ; \
    echo "Latest GLPI tag: ${TAG}" ; \
    curl -fsSL -o glpi.tgz "https://github.com/glpi-project/glpi/releases/download/${TAG}/glpi-${TAG}.tgz" ; \
    tar -xzf glpi.tgz ; \
    rm glpi.tgz ; \
    # Déplacer les fichiers GLPI à la racine du vhost (/var/www/html) SANS /glpi
    rm -rf /var/www/html/* && mv glpi/* /var/www/html/ && rmdir glpi

# Apache: écoute sur 0.0.0.0:80, mod_rewrite, .htaccess autorisé
RUN sed -i 's/^Listen .*/Listen 0.0.0.0:80/' /etc/apache2/ports.conf \
 && a2enmod rewrite headers \
 && printf '%s\n' \
    '<VirtualHost *:80>' \
    '  DocumentRoot /var/www/html' \
    '  <Directory /var/www/html>' \
    '    AllowOverride All' \
    '    Require all granted' \
    '  </Directory>' \
    '  ErrorLog ${APACHE_LOG_DIR}/error.log' \
    '  CustomLog ${APACHE_LOG_DIR}/access.log combined' \
    '</VirtualHost>' \
    > /etc/apache2/sites-available/000-default.conf \
 && chown -R www-data:www-data /var/www/html

EXPOSE 80

# Lancer Apache au premier plan
CMD ["apachectl","-D","FOREGROUND"]