#!/bin/bash
set -euxo pipefail

dnf install -y python3 curl

mkdir -p /opt/route53-lab08

cat > /opt/route53-lab08/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 08</title>
</head>
<body>
    <h1>Route 53 DNS Failover Lab</h1>
    <p>Server: SERVER_ROLE</p>
    <p>Status: HEALTHY</p>
</body>
</html>
HTML

echo "healthy" > /opt/route53-lab08/health

cat > /etc/systemd/system/route53-lab08.service <<'SERVICE'
[Unit]
Description=Route 53 Lab08 Web Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/route53-lab08
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab08.service
