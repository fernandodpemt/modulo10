#!/bin/bash
set -e

systemctl enable httpd
systemctl restart httpd