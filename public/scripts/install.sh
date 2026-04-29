#!/bin/bash
set -e

yum update -y
yum install -y httpd

systemctl enable httpd
systemctl start httpd

mkdir -p /var/www/html
rm -f /var/www/html/index.html

chown -R apache:apache /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;
