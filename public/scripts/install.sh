#!/bin/bash
set -e

yum update -y
yum install -y httpd

mkdir -p /var/www/html/modulo10

chown -R apache:apache /var/www/html/modulo10
chmod -R 755 /var/www/html/modulo10