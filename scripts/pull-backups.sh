#!/usr/bin/env bash
# Copy the backups from the VM to this PC (run on the PC, not on the VM).
#
#   scripts/pull-backups.sh <user>@<vm>:/home/<user>/deploy/backups [local_dir]
#
# local_dir defaults to ~/langrenn-sprint-backups. Run it from cron, e.g. every 5 minutes:
#   */5 * * * * /path/to/deploy/scripts/pull-backups.sh user@vm:/home/user/deploy/backups >> ~/langrenn-sprint-backups/pull.log 2>&1
#
# Settings (environment):
#   BACKUP_SSH_KEY       ssh private key for the VM (otherwise ~/.ssh/config / ssh-agent is used)
#   PULL_KEEP_DAYS       frequent dumps older than this are deleted locally, default 7
#                        (daily dumps are never deleted locally)

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <user>@<vm>:<path to deploy/backups> [local_dir]" >&2
    exit 2
fi
remote=${1%/}/
local_dir=${2:-$HOME/langrenn-sprint-backups}
keep_days=${PULL_KEEP_DAYS:-7}

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

umask 077  # dumps contain personal data
mkdir -p "$local_dir"

exec 9>"$local_dir/.lock"
if ! flock -n 9; then
    log "SKIP previous pull still running"
    exit 0
fi

ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=20)
if [[ -n ${BACKUP_SSH_KEY:-} ]]; then ssh_cmd+=(-i "$BACKUP_SSH_KEY"); fi

# No --delete: files pruned on the VM stay here (until PULL_KEEP_DAYS below).
rsync -a --timeout=120 -e "${ssh_cmd[*]}" \
    --include '/mongo_*.archive.gz' \
    --include '/daily/' --include '/daily/mongo_*.archive.gz' \
    --exclude '*' \
    "$remote" "$local_dir/"

find "$local_dir" -maxdepth 1 -name 'mongo_*.archive.gz' -mtime +"$keep_days" -delete

latest=$(find "$local_dir" -maxdepth 1 -name 'mongo_*.archive.gz' | sort | tail -n1)
log "OK pulled, latest: $(basename "${latest:-none}")"
