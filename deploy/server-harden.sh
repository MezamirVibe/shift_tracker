#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт через sudo" >&2
  exit 1
fi

if ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  if [ ! -e /swapfile ]; then
    fallocate -l 2G /swapfile
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
fi

if ! grep -q '^/swapfile none swap sw 0 0$' /etc/fstab; then
  printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
fi

install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 /opt/shift_tracker/deploy/00-shift-tracker.conf \
  /etc/ssh/sshd_config.d/00-shift-tracker.conf
rm -f /etc/ssh/sshd_config.d/99-shift-tracker.conf
sshd -t
systemctl reload ssh

echo "SWAP:"
swapon --show
echo "SSH effective settings:"
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|maxauthtries) '
