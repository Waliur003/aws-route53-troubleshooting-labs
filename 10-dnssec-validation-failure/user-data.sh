#!/bin/bash
set -euxo pipefail

dnf install -y bind-utils curl

mkdir -p /opt/route53-lab10

echo "Route 53 DNSSEC troubleshooting client" \
  > /opt/route53-lab10/README.txt
