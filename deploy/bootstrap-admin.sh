#!/bin/sh
set -eu

cd /opt/shift_tracker/deploy

if [ ! -f .env ]; then
  echo "Не найден /opt/shift_tracker/deploy/.env" >&2
  exit 1
fi

set -a
. ./.env
set +a

if curl --fail --silent --show-error https://api.mezamir.com/api/v1/auth/bootstrap/status \
  | grep -q '"required":false'; then
  echo "Система уже инициализирована"
  exit 0
fi

admin_login="admin"
admin_password="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa7!"
payload="$(printf '{"login":"%s","password":"%s"}' "$admin_login" "$admin_password")"

response_file="$(mktemp)"
http_code="$(curl --silent --show-error \
  --output "$response_file" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "X-Bootstrap-Token: $BOOTSTRAP_TOKEN" \
  --data "$payload" \
  https://api.mezamir.com/api/v1/auth/bootstrap)"

if [ "$http_code" != "200" ]; then
  echo "Не удалось создать администратора (HTTP $http_code)" >&2
  sed -n '1,5p' "$response_file" >&2
  rm -f "$response_file"
  exit 1
fi

rm -f "$response_file"
printf 'ADMIN_LOGIN=%s\nADMIN_TEMP_PASSWORD=%s\n' "$admin_login" "$admin_password"
