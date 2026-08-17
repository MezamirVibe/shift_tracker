#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install --yes --no-install-recommends \
  ca-certificates \
  curl \
  docker.io \
  docker-compose-v2 \
  fail2ban \
  unattended-upgrades \
  ufw

systemctl enable --now docker
systemctl enable --now fail2ban
systemctl enable --now unattended-upgrades

usermod -aG docker deploy

install -d -m 0750 -o deploy -g deploy /opt/shift_tracker
install -d -m 0700 -o deploy -g deploy /opt/shift_tracker/deploy/backups

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP for ACME redirect'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'HTTP/3'
ufw allow from 92.53.116.12 to any port 10050 proto tcp comment 'Timeweb monitoring'
ufw allow from 92.53.116.111 to any port 10050 proto tcp comment 'Timeweb monitoring'
ufw allow from 92.53.116.119 to any port 10050 proto tcp comment 'Timeweb monitoring'
ufw --force enable

docker --version
docker compose version
ufw status verbose
