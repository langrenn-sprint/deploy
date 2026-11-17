# Shared helpers for backup.sh and restore.sh. Source this file; do not run it.
# shellcheck shell=bash

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# env_file_keys: names defined in .env, one per line. A quoted value that runs
# over several lines is followed to its closing quote, so its lines are not read as
# names; those names are printed again with a "+" in front (a multi-line value).
env_file_keys() {
    [[ -f .env ]] || return 0
    awk '
        q != "" {   # inside a quoted value: look for the closing quote
            rest = $0
            if (q == "\"") gsub(/\\./, "", rest)
            if (index(rest, q)) q = ""
            next
        }
        match($0, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
            head = substr($0, 1, RLENGTH); val = substr($0, RLENGTH + 1)
            sub(/^[ \t]*(export[ \t]+)?/, "", head); sub(/[ \t]*=$/, "", head)
            print head
            sub(/^[ \t]+/, "", val)
            c = substr(val, 1, 1)
            if (c == "\"" || c == "\047") {
                rest = substr(val, 2)
                if (c == "\"") gsub(/\\./, "", rest)
                if (!index(rest, c)) { q = c; print "+" head }
            }
        }
    ' .env
}

# Variables as docker compose resolves them for docker-compose.yml: the process
# environment over .env, with compose's own handling of quotes, escapes, inline
# comments and ${VAR} interpolation inside .env. --no-interpolate skips only
# docker-compose.yml, so a missing ${VAR:?} there does not stop the scripts.
# Loaded once when this file is sourced
# (every script cds to the repo root first). compose's error output is dropped:
# it can quote values from .env.
#
# compose prints one NAME=value per line, with line breaks in values as they are,
# so a value spanning several lines would be cut off, and a following line could
# look like another variable. Multi-line values are not supported: every line must
# be a variable from .env or the process environment, each only once. Otherwise the
# .env variables involved go into ENV_MULTILINE (names only).
declare -gA ENV_RESOLVED=()
export ENV_LOADED=false ENV_MULTILINE=''  # read by check-env.sh
env_load() {
    local out line key name prev='' env_keys proc_keys
    out=$(docker compose config --environment --no-interpolate 2>/dev/null) || return 1
    env_keys=" $(env_file_keys | tr '\n' ' ') "
    # names only: newlines in values become \001 so each variable is one line
    proc_keys=" $(env -0 | tr '\n\0' '\001\n' | sed 's/=.*//' | tr '\n' ' ') "
    ENV_RESOLVED=()
    ENV_MULTILINE=''
    for name in $env_keys; do
        [[ $name == +* ]] && ENV_MULTILINE+=" ${name#+} "
    done
    while IFS= read -r line; do
        key=${line%%=*}
        if [[ $line == *=* && -z ${ENV_RESOLVED[$key]+set} &&
            ($env_keys == *" $key "* || $proc_keys == *" $key "*) ]]; then
            ENV_RESOLVED[$key]=${line#*=}
            prev=$key
            continue
        fi
        # Not a new variable: part of the previous value, or a repeated name.
        for name in "$prev" "$key"; do
            [[ $env_keys == *" $name "* && $ENV_MULTILINE != *" $name "* ]] && ENV_MULTILINE+=" $name "
        done
    done <<<"$out"
    ENV_MULTILINE=$(tr -s ' ' '\n' <<<"$ENV_MULTILINE" | sed '/^$/d' | sort -u | paste -sd' ' -)
    ENV_LOADED=true
}
env_load || log "ERROR docker compose could not read .env or docker-compose.yml (run: docker compose config -q)"
[[ -z $ENV_MULTILINE ]] || log "WARNING .env has values spanning several lines ($ENV_MULTILINE), values may be wrong"

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
