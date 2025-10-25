# Image de base Debian
FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

# Mise à jour et installation des dépendances
RUN apt-get update && \
    apt-get install -y apache2 wget unzip mariadb-server php php-mysql php-cli php-xml php-curl php-gd php-ldap php-imap php-intl php-mbstring php-zip && \
        apt-get clean

        # Téléchargement de GLPI
        WORKDIR /var/www/html
        RUN wget https://github.com/glpi-project/glpi/releases/download/10.0.15/glpi-10.0.15.tgz && \
            tar -xzf glpi-10.0.15.tgz && \
                mv glpi/* . && \
                    rm -rf glpi glpi-10.0.15.tgz

                    # Permissions web
                    RUN chown -R www-data:www-data /var/www/html

                    # Création DB + utilisateur MySQL
                    RUN service mariadb start && \
                        mysql -e "CREATE DATABASE glpi;" && \
                            mysql -e "CREATE USER 'glpi'@'localhost' IDENTIFIED BY 'glpi';" && \
                                mysql -e "GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'localhost';" && \
                                    mysql -e "FLUSH PRIVILEGES;"

                                    # Exposer le port web
                                    EXPOSE 80

                                    # Script de démarrage (Apache + MariaDB)
                                    CMD service mariadb start && apachectl -D FOREGROUND