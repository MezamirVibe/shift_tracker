#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт через sudo" >&2
  exit 1
fi

install -d -m 0755 /etc/docker
install -m 0644 /opt/shift_tracker/deploy/docker-daemon.json /etc/docker/daemon.json
dockerd --validate --config-file=/etc/docker/daemon.json
systemctl restart docker
systemctl is-active --quiet docker
