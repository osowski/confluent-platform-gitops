#!/bin/bash
set -euo pipefail

PROXY_VERSION="${proxy_version}"

# Download pre-built 3proxy binary from S3 via the VPC Gateway endpoint.
# S3 Gateway endpoints are available immediately at instance launch — no NAT
# gateway or internet access required, eliminating the bootstrap race condition
# that caused SSM registration failures when building from source.
aws s3 cp "s3://${infra_binaries_bucket}/binaries/3proxy-$PROXY_VERSION-linux-x86_64" /usr/local/bin/3proxy
chmod 755 /usr/local/bin/3proxy

mkdir -p /etc/3proxy /var/log/3proxy

cat > /etc/3proxy/3proxy.cfg << 'CONF'
nscache 65536
# Explicit no-auth — proxy is bound to 127.0.0.1 only (SSM port-forward).
# auth none is required for ACL directives to function correctly.
auth none
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%.  %N.%p %E %U %C:%c %R:%r %O %I %h %T"
socks -p1080 -i127.0.0.1
CONF

cat > /etc/systemd/system/3proxy.service << 'UNIT'
[Unit]
Description=3proxy SOCKS5 proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=32768

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

# Ensure SSM agent is running — AL2023 ships with it pre-installed but the
# service may not be active if it failed to reach IMDS during early boot.
systemctl enable amazon-ssm-agent
systemctl restart amazon-ssm-agent
