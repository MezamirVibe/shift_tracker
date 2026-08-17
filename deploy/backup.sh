#!/bin/sh
set -eu

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
pg_dump --format=custom --file="/backups/shift_tracker_${timestamp}.dump"
find /backups -type f -name 'shift_tracker_*.dump' -mtime "+${BACKUP_RETENTION_DAYS}" -delete
