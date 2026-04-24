#!/bin/bash
set -euo pipefail

# Build 3proxy from source — avoids AL2023 package repo uncertainty.
# Pinned to a specific release tag for reproducibility.
PROXY_VERSION="0.9.6"

yum install -y git gcc make

# Wait for internet connectivity before attempting clone
until curl -s --max-time 5 https://github.com 2>&1 >/dev/null;
do
  echo "Waiting for internet connectivity..."
  sleep 5
done

git clone --depth 1 --branch "$PROXY_VERSION" \
  https://github.com/3proxy/3proxy.git /opt/3proxy

cd /opt/3proxy && make -f Makefile.Linux

# Fail loudly if the build didn't produce the expected binary
test -f bin/3proxy || { echo "ERROR: 3proxy build failed — binary not found" >&2; exit 1; }

install -m 755 bin/3proxy /usr/local/bin/3proxy

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
