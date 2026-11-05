#!/usr/bin/env bash
# Write status/system.json: instance, backup status, restore info, MongoDB info, disk,
# and the services (containers and images) of this compose project.
# The GUIs read this file (mounted read-only). Format: see issue #13.
# Contains no personal data or secrets: only names, counts, sizes and timestamps.
#
#   scripts/status.sh                                     refresh (systemd timer every 30 s, restore.sh)
#   scripts/status.sh backup-ok <file> <seconds> <upload>   called by backup.sh, upload: ok|failed|disabled
#   scripts/status.sh backup-failed <message>               called by backup.sh

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
# shellcheck source=_common.sh
source scripts/_common.sh

umask 022  # the GUI containers must be able to read the folder and file
STATUS_DIR=status
mkdir -p "$STATUS_DIR"
if [[ ! -w $STATUS_DIR ]]; then
    log "ERROR $STATUS_DIR/ is not writable (created by docker as root?): sudo chown $(id -un) $STATUS_DIR"
    exit 1
fi

# One writer at a time: a periodic refresh must not overwrite a backup result
# written at the same moment (the file is read, updated and written back).
exec 8>"$STATUS_DIR/.lock"
if ! flock -w 60 8; then
    log "ERROR timed out waiting for $STATUS_DIR/.lock"
    exit 1
fi

status_js='
const out = {version: c.version(), databases: []};
for (const d of c.adminCommand({listDatabases: 1}).databases) {
  if (["admin", "config", "local", "deploy_system"].includes(d.name)) continue;
  const s = c.getSiblingDB(d.name);
  const cols = {};
  for (const n of s.getCollectionNames().sort()) cols[n] = s.getCollection(n).estimatedDocumentCount();
  out.databases.push({name: d.name, size_bytes: Number(d.sizeOnDisk), collections: cols});
}
const r = c.getSiblingDB("deploy_system").restores.find({}, {_id: 0}).sort({_id: -1}).limit(1).toArray();
out.last_restore = r.length ? r[0] : null;
print(JSON.stringify(out));
'

MONGO_JSON=$(mongo_eval "$status_js" 2>/dev/null) || MONGO_JSON=
read -r DISK_TOTAL DISK_FREE < <(df -B1 --output=size,avail . | tail -n1)

# Containers and their images, read from Docker (no change needed in the services).
COMPOSE_SERVICES=$(docker compose config --services 2>/dev/null || true)
container_ids=$(docker compose ps -a -q 2>/dev/null || true)
CONTAINERS_JSON='[]'
IMAGES_JSON='[]'
if [[ -n $container_ids ]]; then
    # shellcheck disable=SC2086  # word splitting of the id list is intended
    CONTAINERS_JSON=$(docker inspect $container_ids 2>/dev/null || echo '[]')
    image_ids=$(docker inspect --format '{{.Image}}' $container_ids 2>/dev/null | sort -u)
    # shellcheck disable=SC2086
    [[ -n $image_ids ]] && IMAGES_JSON=$(docker image inspect $image_ids 2>/dev/null || echo '[]')
fi

export MONGO_JSON DISK_TOTAL DISK_FREE COMPOSE_SERVICES CONTAINERS_JSON IMAGES_JSON
export STATUS_FILE="$STATUS_DIR/system.json"
export BACKUP_DIR; BACKUP_DIR=$(env_get BACKUP_DIR backups)
export INSTANCE_NAME; INSTANCE_NAME=$(env_get INSTANCE_NAME)
export INSTANCE_ROLE; INSTANCE_ROLE=$(env_get INSTANCE_ROLE unknown)

python3 -I - "$@" <<'PY'
import datetime, json, os, re, sys, tempfile

env = os.environ
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
path = env["STATUS_FILE"]

try:
    with open(path) as f:
        old = json.load(f)
except (OSError, ValueError):
    old = {}

backup = old.get("backup") or {
    "last_attempt": None, "last_result": None, "last_error": None,
    "last_success": None, "upload": {"status": None, "time": None},
}
args = sys.argv[1:]
if args[:1] == ["backup-ok"] and len(args) == 4:
    file, seconds, upload = args[1], int(args[2]), args[3]
    backup.update(last_attempt=now, last_result="ok", last_error=None, last_success={
        "time": now,
        "file": os.path.basename(file),
        "size_bytes": os.path.getsize(file),
        "duration_seconds": seconds,
    })
    backup["upload"] = {"status": upload, "time": now}
elif args[:1] == ["backup-failed"] and len(args) == 2:
    backup.update(last_attempt=now, last_result="failed", last_error=args[1])
elif args:
    sys.exit(f"usage: status.sh [backup-ok <file> <seconds> <upload> | backup-failed <message>]")

mongo = None
for line in reversed(env.get("MONGO_JSON", "").splitlines()):
    try:
        mongo = json.loads(line)
        break
    except ValueError:
        pass
if mongo is not None:
    restore = mongo.pop("last_restore", None)
    mongodb = {"available": True, **mongo}
else:
    restore = old.get("restore")  # database down: keep the last known value
    mongodb = {"available": False}

def docker_time(value):
    """Docker's UTC nanosecond timestamps -> local ISO 8601, None for unset/zero."""
    if not value or value.startswith("0001-"):
        return None
    value = re.sub(r"(\.\d{1,6})\d*", r"\1", value).replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(value).astimezone().isoformat(timespec="seconds")
    except ValueError:
        return None

images = {i["Id"]: i for i in json.loads(env["IMAGES_JSON"] or "[]")}
services = {}
for c in json.loads(env["CONTAINERS_JSON"] or "[]"):
    labels = c["Config"].get("Labels") or {}
    name = labels.get("com.docker.compose.service") or c["Name"].lstrip("/")
    image = images.get(c["Image"], {})
    oci = (image.get("Config") or {}).get("Labels") or {}
    digests = image.get("RepoDigests") or []
    services[name] = {
        "name": name,
        "state": c["State"]["Status"],
        "started_at": docker_time(c["State"].get("StartedAt")),
        "image": c["Config"]["Image"],
        "image_id": c["Image"],
        "image_digest": digests[0].split("@", 1)[1] if digests else None,
        "image_created": docker_time(image.get("Created")),
        "revision": oci.get("org.opencontainers.image.revision"),
        "source": oci.get("org.opencontainers.image.source"),
    }
for name in env["COMPOSE_SERVICES"].split():
    services.setdefault(name, {"name": name, "state": "missing"})

status = {
    "schema_version": 1,
    "generated_at": now,
    "instance": {"name": env["INSTANCE_NAME"] or None, "role": env["INSTANCE_ROLE"]},
    "backup": backup,
    "restore": restore,
    "mongodb": mongodb,
    "disk": {"total_bytes": int(env["DISK_TOTAL"]), "free_bytes": int(env["DISK_FREE"])},
    "services": sorted(services.values(), key=lambda s: s["name"]),
}

# Atomic write, world-readable so the GUI container can read it whatever its user is.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".system.", suffix=".json")
with os.fdopen(fd, "w") as f:
    json.dump(status, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
