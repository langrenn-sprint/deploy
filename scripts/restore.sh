#!/usr/bin/env bash
# Restore a MongoDB dump made by backup.sh into the mongodb service of this compose project.
# Works on the VM, on a new VM, or on a local PC (needs this repo + a .env file).
#
#   scripts/restore.sh backups/mongo_20261105_120500.archive.gz
#   scripts/restore.sh -y <file>     # no confirmation prompt
#
# Collections in the dump REPLACE the ones in the database (--drop).
# Users (admin db) are not touched: the database keeps the DB_USER/DB_PASSWORD from .env.
# After the restore, start the rest of the services: docker compose up -d

set -euo pipefail

yes=false
if [[ ${1:-} == -y ]]; then yes=true; shift; fi
if [[ $# -ne 1 || ! -f $1 ]]; then
    echo "Usage: $0 [-y] <mongo_*.archive.gz>" >&2
    exit 2
fi
archive=$(readlink -f "$1")

cd "$(dirname "$(readlink -f "$0")")/.."
# shellcheck source=_common.sh
source scripts/_common.sh

gzip -t "$archive" || { log "ERROR $archive is not a valid gzip archive"; exit 1; }

if ! $yes; then
    echo "This replaces the data in the mongodb service of $(pwd) with:"
    echo "  $archive"
    echo "Tip: stop the app services first (docker compose stop) so nothing writes during the restore."
    read -r -p "Continue? [y/N] " answer
    [[ $answer == [yY]* ]] || exit 1
fi

docker compose up -d mongodb

# Wait until the real server is up. On a fresh data dir the image first runs a
# temporary init server bound to 127.0.0.1 only, so ping via the service name.
log "waiting for mongodb ..."
for _ in $(seq 60); do
    if docker compose exec -T mongodb mongosh --host mongodb --quiet \
        --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

log "restoring $archive"
mongo_tool mongorestore --archive --gzip --drop \
    --nsExclude 'admin.*' --nsExclude 'config.*' < "$archive"
log "OK restore done. Start the services with: docker compose up -d"
