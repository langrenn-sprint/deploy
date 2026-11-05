#!/usr/bin/env bash
# Hot backup of MongoDB: no downtime, the database keeps running.
#
# Run on the VM from cron, e.g. every 5 minutes:
#   */5 * * * * /home/<user>/deploy/scripts/backup.sh >> /home/<user>/deploy/backups/backup.log 2>&1
#
# What it does:
#   1. mongodump --archive --gzip  ->  backups/mongo_YYYYmmdd_HHMMSS.archive.gz
#   2. keeps the latest dump of each day in backups/daily/mongo_YYYYmmdd.archive.gz
#   3. prunes dumps older than BACKUP_KEEP_HOURS (frequent) / BACKUP_KEEP_DAYS (daily)
#   4. if BACKUP_GCS_BUCKET is set: uploads new files to Google Cloud Storage (rclone)
#
# Settings (environment or .env):
#   BACKUP_DIR             default: backups
#   BACKUP_KEEP_HOURS      default: 48
#   BACKUP_KEEP_DAYS       default: 30
#   BACKUP_GCS_BUCKET      optional, e.g. langrenn-sprint-backup (must be a PRIVATE bucket)
#   BACKUP_GCS_PREFIX      default: mongo
#   BACKUP_GCS_CREDENTIALS service account key file with write access to the bucket
#                          default: backup-sa.json

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
# shellcheck source=_common.sh
source scripts/_common.sh

BACKUP_DIR=$(env_get BACKUP_DIR backups)
KEEP_HOURS=$(env_get BACKUP_KEEP_HOURS 48)
KEEP_DAYS=$(env_get BACKUP_KEEP_DAYS 30)
GCS_BUCKET=$(env_get BACKUP_GCS_BUCKET)
GCS_PREFIX=$(env_get BACKUP_GCS_PREFIX mongo)
GCS_CREDENTIALS=$(env_get BACKUP_GCS_CREDENTIALS backup-sa.json)
RCLONE_IMAGE=$(env_get BACKUP_RCLONE_IMAGE rclone/rclone:latest)

umask 077  # dumps contain personal data: readable by the owner only
mkdir -p "$BACKUP_DIR/daily"
BACKUP_DIR=$(readlink -f "$BACKUP_DIR")

# Never run two backups at once (e.g. if one hangs longer than the cron interval).
exec 9>"$BACKUP_DIR/.lock"
if ! flock -n 9; then
    log "SKIP previous backup still running"
    exit 0
fi

# 1. Dump
ts=$(date +%Y%m%d_%H%M%S)
file="$BACKUP_DIR/mongo_$ts.archive.gz"
tmp="$file.partial"
trap 'rm -f "$tmp"' EXIT

start=$SECONDS
if ! mongo_tool mongodump --quiet --archive --gzip > "$tmp"; then
    log "ERROR mongodump failed"
    exit 1
fi
if ! gzip -t "$tmp" 2>/dev/null; then
    log "ERROR dump is not a valid gzip archive: $tmp"
    exit 1
fi
mv "$tmp" "$file"
log "OK $(basename "$file") $(du -h "$file" | cut -f1) in $((SECONDS - start))s"

# 2. Daily copy: always the latest dump of the day
cp -p "$file" "$BACKUP_DIR/daily/mongo_${ts%%_*}.archive.gz"

# 3. Prune
find "$BACKUP_DIR" -maxdepth 1 -name 'mongo_*.archive.gz' -mmin +$((KEEP_HOURS * 60)) -delete
find "$BACKUP_DIR" -maxdepth 1 -name 'mongo_*.partial' -mmin +60 -delete
find "$BACKUP_DIR/daily" -maxdepth 1 -name 'mongo_*.archive.gz' -mtime +"$KEEP_DAYS" -delete

# 4. Off-VM copy to Google Cloud Storage
if [[ -n $GCS_BUCKET ]]; then
    if [[ ! -f $GCS_CREDENTIALS ]]; then
        log "ERROR BACKUP_GCS_CREDENTIALS file not found: $GCS_CREDENTIALS"
        exit 1
    fi
    # Only files from the last 24h are considered, so a GCS outage up to a day is
    # caught up automatically. Retention in the bucket: use a GCS lifecycle rule.
    if docker run --rm --user "$(id -u):$(id -g)" \
        -v "$BACKUP_DIR:/data:ro" \
        -v "$(readlink -f "$GCS_CREDENTIALS"):/creds.json:ro" \
        -e RCLONE_CONFIG_GCS_TYPE="${BACKUP_RCLONE_TYPE:-google cloud storage}" \
        -e RCLONE_CONFIG_GCS_SERVICE_ACCOUNT_FILE=/creds.json \
        -e RCLONE_CONFIG_GCS_BUCKET_POLICY_ONLY=true \
        -e RCLONE_CONFIG=/dev/null \
        "$RCLONE_IMAGE" copy /data "gcs:$GCS_BUCKET/$GCS_PREFIX" \
        --max-age 24h \
        --include '/mongo_*.archive.gz' --include '/daily/mongo_*.archive.gz' \
        -q; then
        log "OK uploaded to gs://$GCS_BUCKET/$GCS_PREFIX"
    else
        log "ERROR upload to gs://$GCS_BUCKET/$GCS_PREFIX failed (local dump kept)"
        exit 1
    fi
fi
