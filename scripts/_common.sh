# Shared helpers for backup.sh and restore.sh. Source this file; do not run it.

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# env_get KEY [DEFAULT]: value from the process environment, else from .env, else DEFAULT.
env_get() {
    local key=$1 default=${2:-} val
    if [[ -n ${!key:-} ]]; then
        printf '%s' "${!key}"
        return
    fi
    val=$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true)
    val=${val%\"}; val=${val#\"}; val=${val%\'}; val=${val#\'}
    printf '%s' "${val:-$default}"
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
