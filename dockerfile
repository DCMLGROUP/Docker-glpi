# Image de base
FROM ubuntu:24.04

RUN apt update && apt upgrade -y

RUN apt-get install -y apache2 mariadb-server wget tar unzip php php-mysql php-xml php-curl php-gd php-ldap php-intl php-mbstring php-zip php-imap

CMD ["apachectl","-D","FOREGROUND"]

EXPOSE 80/tcp
