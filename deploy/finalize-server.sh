#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт через sudo" >&2
  exit 1
fi

rm -f /etc/sudoers.d/90-deploy-codex
visudo -c >/dev/null
sshd -t

echo "SERVER_FINALIZE_OK"
echo "SSH:"
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|maxauthtries) '
echo "SWAP:"
swapon --show
echo "FIREWALL:"
ufw status | sed -n '1,16p'
