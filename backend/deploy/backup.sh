#!/bin/sh
# Runs inside the backup container: one pg_dump per day, keep the newest 14.
set -u
while true; do
  pg_dump -h db -U nearby -Fc nearby > "/backups/nearby-$(date +%F).dump"
  ls -1t /backups/nearby-*.dump 2>/dev/null | tail -n +15 | while read -r old; do
    rm -f -- "$old"
  done
  sleep 86400
done
