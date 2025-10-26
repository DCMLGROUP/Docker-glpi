# Image de base
FROM ubuntu:24.04

RUN apt update && apt upgrade -y

RUN apt-get install -y apache2 mariadb-server wget tar unzip php php-mysql php-xml php-curl php-gd php-ldap php-intl php-mbstring php-zip php-imap

WORKDIR /tmp

RUN wget https://github.com/glpi-project/glpi/releases/download/11.0.1/glpi-11.0.1.tgz

CMD ["apachectl","-D","FOREGROUND"]
EXPOSE 80/tcp
