#!/bin/bash
set -euxo pipefail

dnf install -y python3 curl bind-utils

mkdir -p /opt/route53-lab07

cat > /opt/route53-lab07/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 07</title>
</head>
<body>
    <h1>Route 53 Health Check Lab</h1>
    <p>Application is healthy.</p>
    <p>HTTP port: 8080</p>
</body>
</html>
HTML

echo "healthy" > /opt/route53-lab07/health

cat > /etc/systemd/system/route53-lab07.service <<'SERVICE'
[Unit]
Description=Route 53 Lab07 HTTP Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/route53-lab07
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab07.service
