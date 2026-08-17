#!/bin/sh
set -eu

latest="$(find /backups -maxdepth 1 -type f -name 'shift_tracker_*.dump' | sort | tail -n 1)"
if [ -z "$latest" ]; then
  echo "BACKUP_VERIFY_FAILED: backup not found" >&2
  exit 1
fi

pg_restore --list "$latest" >/dev/null
echo "BACKUP_VERIFY_OK: $(basename "$latest")"
