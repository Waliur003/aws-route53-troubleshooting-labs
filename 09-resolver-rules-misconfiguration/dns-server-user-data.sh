#!/bin/bash
set -euxo pipefail

dnf install -y dnsmasq bind-utils

mkdir -p /etc/route53-lab09

cat > /etc/route53-lab09/dnsmasq.conf <<'CONF'
port=53
listen-address=10.62.1.10
bind-interfaces

no-resolv
no-hosts

local=/corp.lab09.test/
host-record=app.corp.lab09.test,10.62.1.100,30

log-queries
CONF

cat > /etc/systemd/system/route53-lab09-dns.service <<'SERVICE'
[Unit]
Description=Route 53 Lab09 Corporate DNS
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/route53-lab09-dns.pid
ExecStart=/usr/sbin/dnsmasq --conf-file=/etc/route53-lab09/dnsmasq.conf --pid-file=/run/route53-lab09-dns.pid
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab09-dns.service
