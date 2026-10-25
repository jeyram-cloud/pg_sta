#!/usr/bin/env bash
# Run psql as the postgres user on the development VM.
#
#   scripts/psql.sh -c "SELECT ..."          run a single statement
#   scripts/psql.sh -f file.sql              run a script file
#   cat file.sql | scripts/psql.sh           run a script on stdin
#
# Options: -d DB  (default $PG_STA_PGDATABASE, i.e. pg_sta_qa)
#          -X/-q/-A/-t  psql flags passed straight through
set -euo pipefail

PG_STA_HOST=${PG_STA_HOST:-127.0.0.1}
PG_STA_SSH_PORT=${PG_STA_SSH_PORT:-2201}
PG_STA_SSH_KEY=${PG_STA_SSH_KEY:-$HOME/.vagrant.d/insecure_private_key}
PG_STA_PGDATABASE=${PG_STA_PGDATABASE:-pg_sta_qa}

DB="$PG_STA_PGDATABASE"
PSQL_FLAGS=(-X -v ON_ERROR_STOP=1)
SQL=""
MODE="stdin"

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DB="$2"; shift 2 ;;
        -c) SQL="$2"; MODE="cmd"; shift 2 ;;
        -f) SQL="$2"; MODE="file"; shift 2 ;;
        -*) PSQL_FLAGS+=("$1"); shift ;;
        *)  echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

case "$MODE" in
    cmd)  printf '%s\n' "$SQL" > "$TMP" ;;
    file) cp "$SQL" "$TMP" ;;
    stdin) cat > "$TMP" ;;
esac

FLAGSTR=""
for f in "${PSQL_FLAGS[@]}"; do FLAGSTR="$FLAGSTR $f"; done

ssh -i "$PG_STA_SSH_KEY" -p "$PG_STA_SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "vagrant@$PG_STA_HOST" \
    "sudo -u postgres psql$FLAGSTR -d '$DB'" < "$TMP"
