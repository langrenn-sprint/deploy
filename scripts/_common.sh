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
