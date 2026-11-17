# Shared helpers for backup.sh and restore.sh. Source this file; do not run it.
# shellcheck shell=bash

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# Variables as docker compose resolves them for docker-compose.yml: the process
# environment over .env, with compose's own handling of quotes, escapes, inline
# comments and ${VAR} interpolation. Loaded once when this file is sourced
# (every script cds to the repo root first). compose's error output is dropped:
# it can quote values from .env.
declare -gA ENV_RESOLVED=()
export ENV_LOADED=false  # read by check-env.sh
env_load() {
    local out line
    out=$(docker compose config --environment 2>/dev/null) || return 1
    ENV_RESOLVED=()
    while IFS= read -r line; do
        [[ $line == *=* ]] && ENV_RESOLVED[${line%%=*}]=${line#*=}
    done <<<"$out"
    ENV_LOADED=true
}
env_load || log "ERROR docker compose could not read .env or docker-compose.yml (run: docker compose config -q)"

# env_get KEY [DEFAULT]: resolved value of KEY, else DEFAULT.
env_get() {
    local val=${ENV_RESOLVED[$1]:-}
    printf '%s' "${val:-${2:-}}"
}

# mongo_tool <tool> [args...]: run mongodump or mongorestore
# in the running mongodb container, logged in as the root user.
# The password goes into a temporary config file inside the container, so it never
# appears on a command line (visible to anyone running `ps` on the VM).
# stdin and stdout go through to the tool, so archives can be piped in and out.
mongo_tool() {
    # shellcheck disable=SC2016  # expanded inside the container, not here
    local inner='
set -e
umask 077
cfg=$(mktemp)
trap "rm -f \"$cfg\"" EXIT
pw=$(printf "%s" "$MONGO_INITDB_ROOT_PASSWORD" | sed "s/'"'"'/'"''"'/g")
printf "password: '"'"'%s'"'"'\n" "$pw" > "$cfg"
tool=$1; shift
"$tool" --config "$cfg" --username "$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase admin "$@"
'
    docker compose exec -T mongodb sh -c "$inner" sh "$@"
}

# mongo_eval <js> [docker compose exec options...]: run JavaScript in mongosh inside the
# mongodb container. `c` is an authenticated connection to the admin database.
# Credentials are read from the container's environment, never from a command line.
# Extra arguments go to `docker compose exec`, e.g. -e NAME=value to pass values to the
# script (read them with process.env.NAME).
mongo_eval() {
    local js=$1; shift
    docker compose exec -T "$@" mongodb mongosh --nodb --quiet --eval "
const c = connect('mongodb://127.0.0.1:27017/admin');
c.auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD);
$js"
}
