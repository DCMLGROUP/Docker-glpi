# Image de base
FROM debian:12-slim

RUN apt update && apt upgrade -y

RUN apt-get install -y apache2 mariadb-server wget tar unzip php php-mysql php-xml php-curl php-gd php-ldap php-intl php-mbstring php-zip php-imap

CMD ["apache2-foreground"]

EXPOSE 80/tcp
