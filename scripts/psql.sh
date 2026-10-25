#!/usr/bin/env bash
# Run psql as the postgres user on the development VM.
#
#   scripts/psql.sh -c "SELECT ..."          run a single statement
#   scripts/psql.sh -f file.sql              run a script file
#   cat file.sql | scripts/psql.sh           run a script on stdin
#
# Options: -d DB  (default $PG_STA_PGDATABASE, i.e. pg_sta_qa)
#          -X/-q/-A/-t  psql flags passed straight through
#
# The script works both on the workstation (over SSH) and on the VM itself
# (through the local psql client); the transport is detected automatically.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/pg_sta_conn.sh
. "$HERE/pg_sta_conn.sh"

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

pg_sta_resolve_mode

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

case "$MODE" in
    cmd)  printf '%s\n' "$SQL" > "$TMP" ;;
    file) cp "$SQL" "$TMP" ;;
    stdin) cat > "$TMP" ;;
esac

FLAGSTR=""
for f in "${PSQL_FLAGS[@]}"; do FLAGSTR="$FLAGSTR $f"; done

pg_sta_psql "$DB" "$FLAGSTR" < "$TMP"
