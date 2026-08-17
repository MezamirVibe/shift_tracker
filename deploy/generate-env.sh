#!/bin/sh
set -eu

cd /opt/shift_tracker/deploy

if [ -f .env ]; then
  chmod 600 .env
  exit 0
fi

umask 077
postgres_password="$(openssl rand -hex 32)"
jwt_secret="$(openssl rand -hex 48)"
bootstrap_token="$(openssl rand -hex 48)"

printf '%s\n' \
  'POSTGRES_DB=shift_tracker' \
  'POSTGRES_USER=shift_tracker' \
  "POSTGRES_PASSWORD=${postgres_password}" \
  "JWT_SECRET=${jwt_secret}" \
  "BOOTSTRAP_TOKEN=${bootstrap_token}" \
  'ACCESS_TOKEN_MINUTES=15' \
  'REFRESH_TOKEN_DAYS=30' \
  'BACKUP_RETENTION_DAYS=14' \
  'CORS_ORIGINS=' > .env

chmod 600 .env
