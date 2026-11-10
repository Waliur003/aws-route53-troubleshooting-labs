#!/bin/bash
set -euxo pipefail

dnf install -y python3 bind-utils curl

mkdir -p /opt/route53-lab06

cat > /opt/route53-lab06/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Route 53 Lab 06</title>
</head>
<body>
    <h1>Route 53 Alias Troubleshooting</h1>
    <p>Healthy application behind the correct ALB.</p>
    <p>Lab 06 - Incorrect Alias Record</p>
</body>
</html>
HTML

cat > /etc/systemd/system/route53-lab06.service <<'SERVICE'
[Unit]
Description=Route 53 Lab06 HTTP Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/route53-lab06
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now route53-lab06.service
