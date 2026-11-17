#!/usr/bin/env bash
# Check that .env has what docker-compose.yml and the scripts need.
# Run it on a new or recovery instance before starting it; restore.sh runs it first.
# Prints variable names only, never values.
#
#   scripts/check-env.sh     # exit 0: OK (warnings allowed), 1: errors
#
# Checks:
#   - every required ${VAR:?} in docker-compose.yml is set (compose stops at the first
#     missing one, this lists them all)
#   Values are read as docker compose resolves them (shell environment over .env,
#   quotes and ${VAR} interpolation), so DB_PASSWORD=${UNSET} counts as empty.
#   - secrets are not empty, a placeholder from .env.example or a known example value
#   - FERNET_KEY is a valid key (32 bytes, urlsafe base64)
#   - files and folders that docker-compose.yml bind-mounts exist
#     (if not, Docker creates an empty folder in their place)
#   - backup settings, .env file permissions, keys in .env.example missing in .env

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
# shellcheck source=_common.sh
source scripts/_common.sh

errors=0
warnings=0
error() { log "ERROR $*"; errors=$((errors + 1)); }
warn() { log "WARNING $*"; warnings=$((warnings + 1)); }

# Keys defined in an env file (ignores comments and blank lines).
# Succeeds with no output for an empty or comments-only file.
env_keys() { { grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" || true; } | tr -d = ; }

# Warn if a file is readable by group or others.
check_private() {
    local mode
    mode=$(stat -c %a "$1")
    [[ $mode == *00 ]] || warn "$1 is readable by others (mode $mode): chmod 600 $1"
}

if [[ ! -f .env ]]; then
    error ".env not found: cp .env.example .env && chmod 600 .env, then fill it in"
    exit 1
fi
check_private .env
if [[ $ENV_LOADED != true ]]; then
    error ".env or docker-compose.yml is invalid, see above"
    exit 1
fi

dups=$(env_keys .env | sort | uniq -d | paste -sd' ' -)
[[ -z $dups ]] || warn ".env sets these more than once (the last one wins): $dups"

if [[ -f .env.example ]]; then
    missing=$(comm -23 <(env_keys .env.example | sort -u) <(env_keys .env | sort -u) | paste -sd' ' -)
    [[ -z $missing ]] || warn "in .env.example but not in .env: $missing"
fi

# 1. Variables docker-compose.yml requires: ${VAR:?} (or ${VAR} without a default).
unset_keys=''
while read -r key; do
    [[ -n $(env_get "$key") ]] || { error "$key is not set"; unset_keys+=" $key "; }
done < <(grep -oE '\$\{[A-Z0-9_]+(:\?[^}]*)?\}' docker-compose.yml | sed -E 's/^.\{([A-Z0-9_]+).*/\1/' | sort -u)

# 2. Secrets: no placeholders or example values.
for key in JWT_SECRET FERNET_KEY DB_PASSWORD ADMIN_PASSWORD; do
    val=$(env_get "$key")
    case ${val,,} in
        '') [[ $unset_keys == *" $key "* ]] || error "$key is not set" ;;
        \<*\> | secret | password | admin | changeme)
            error "$key is a placeholder or example value: set a real one" ;;
        *) ((${#val} >= 12)) || warn "$key is short (${#val} characters)" ;;
    esac
done

key=$(env_get FERNET_KEY)
if [[ -n $key && $key != \<*\> ]]; then
    if [[ ${#key} -ne 44 ]] ||
        [[ $(printf '%s' "$key" | tr -- '-_' '+/' | base64 -d 2>/dev/null | wc -c) -ne 32 ]]; then
        error "FERNET_KEY is not a valid key (44 characters, urlsafe base64 of 32 bytes), see README"
    fi
fi

# 3. Other values with a fixed format.
case $(env_get INSTANCE_ROLE) in
    production | standby | test) ;;
    '') warn "INSTANCE_ROLE is not set (production | standby | test)" ;;
    *) error "INSTANCE_ROLE must be production, standby or test" ;;
esac
[[ -n $(env_get INSTANCE_NAME) && $(env_get INSTANCE_NAME) != \<*\> ]] ||
    warn "INSTANCE_NAME is not set (shown in the GUI)"
case $(env_get SESSION_COOKIE_SECURE false) in
    true | false) ;;
    *) error "SESSION_COOKIE_SECURE must be true or false" ;;
esac
for key in JWT_EXP_DELTA_SECONDS JWT_MAX_SESSION_SECONDS; do
    val=$(env_get "$key")
    [[ -z $val || $val =~ ^0*[1-9][0-9]*$ ]] || error "$key must be a positive number of seconds"
done

# 4. Bind-mounted files and folders (long syntax "source:" in docker-compose.yml).
# Mounts listed here must be folders, all others files. Add new folder mounts here.
# shellcheck disable=SC2016  # matched literally against docker-compose.yml
DIR_MOUNTS=('./status' '${LOCAL_PHOTO_DIRECTORY:?}')
while read -r line; do
    # Replace each ${VAR} once, left to right. Resolved values are not scanned
    # again, so a value that itself contains ${...} cannot loop.
    src='' rest=$line
    while [[ $rest =~ \$\{([A-Z0-9_]+)(:\?[^\}]*)?\} ]]; do
        src+=${rest%%"${BASH_REMATCH[0]}"*}$(env_get "${BASH_REMATCH[1]}")
        rest=${rest#*"${BASH_REMATCH[0]}"}
    done
    src+=$rest
    want='file'
    for d in "${DIR_MOUNTS[@]}"; do [[ $line == "$d" ]] && want=folder; done
    if [[ -z $src ]]; then
        error "$line is mounted by docker-compose.yml but is empty"
    elif [[ ! -e $src ]]; then
        error "$src is mounted by docker-compose.yml but does not exist (expected a $want)"
    elif [[ $want == folder && ! -d $src ]]; then
        error "$src is mounted by docker-compose.yml and must be a folder"
    elif [[ $want == file && ! -f $src ]]; then
        error "$src is mounted by docker-compose.yml and must be a file (a folder here is usually created by Docker when the file was missing)"
    fi
done < <(sed -nE 's/^[[:space:]]*source:[[:space:]]*//p' docker-compose.yml | sort -u)
[[ ! -f application_default_credentials.json ]] || check_private application_default_credentials.json

# 5. Backup to Google Cloud Storage.
if [[ -n $(env_get BACKUP_GCS_BUCKET) ]]; then
    creds=$(env_get BACKUP_GCS_CREDENTIALS backup-sa.json)
    if [[ -f $creds ]]; then
        check_private "$creds"
    else
        error "BACKUP_GCS_BUCKET is set but $creds (BACKUP_GCS_CREDENTIALS) does not exist"
    fi
fi

# 6. Anything else docker compose rejects. Its output is dropped: it can quote values.
if ((errors == 0)) && ! docker compose config -q >/dev/null 2>&1; then
    error "docker compose config fails: run docker compose config -q (it may print values)"
fi

if ((errors > 0)); then
    log "ERROR .env: $errors error(s), $warnings warning(s)"
    exit 1
fi
log "OK .env: $warnings warning(s)"
