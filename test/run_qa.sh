#!/usr/bin/env bash
#
# pg_sta QA suite runner.
#
# The QA suite builds a synthetic workload that deliberately contains a known
# set of defects, then asserts that pg_sta actually detects each of them.
# It is complementary to the regression suite:
#
#   regression  ->  contract behaviour (types, determinism, error handling)
#   QA          ->  detection capability (does the advisor find real problems)
#
# The suite runs entirely inside schema "sta_qa" of a dedicated QA database.
# It never touches objects outside that schema.
#
# Usage:
#   test/run_qa.sh              run against the default QA database
#   test/run_qa.sh -d mydb     run against another database
#
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PG_STA_HOST=${PG_STA_HOST:-127.0.0.1}
PG_STA_SSH_PORT=${PG_STA_SSH_PORT:-2201}
PG_STA_SSH_KEY=${PG_STA_SSH_KEY:-$HOME/.vagrant.d/insecure_private_key}
PG_STA_PGDATABASE=${PG_STA_PGDATABASE:-pg_sta_qa}

while [ $# -gt 0 ]; do
    case "$1" in
        -d) PG_STA_PGDATABASE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

SSH=(ssh -i "$PG_STA_SSH_KEY" -p "$PG_STA_SSH_PORT"
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o LogLevel=ERROR)

# The QA files are copied to the VM because /home/vagrant is not traversable
# by the postgres user.
WORKDIR=/tmp/pg_sta_qa_run
SETUP="$WORKDIR/qa_setup.sql"
ASSERT="$WORKDIR/qa_assertions.sql"

echo "==> staging QA files to $PG_STA_HOST:$WORKDIR"
"${SSH[@]}" "vagrant@$PG_STA_HOST" "mkdir -p '$WORKDIR' && chmod 755 '$WORKDIR'"
scp -q -i "$PG_STA_SSH_KEY" -P "$PG_STA_SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$ROOT/test/qa_setup.sql"       "vagrant@$PG_STA_HOST:$SETUP"
scp -q -i "$PG_STA_SSH_KEY" -P "$PG_STA_SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$ROOT/test/qa_assertions.sql"  "vagrant@$PG_STA_HOST:$ASSERT"
chmod 644 "$SETUP" "$ASSERT" 2>/dev/null || true

echo "==> ensuring database '$PG_STA_PGDATABASE' and extension exist"
"${SSH[@]}" "vagrant@$PG_STA_HOST" "
    set -e
    sudo -u postgres psql -X -tAc \"SELECT 1 FROM pg_database WHERE datname='$PG_STA_PGDATABASE'\" \
        | grep -q 1 || sudo -u postgres createdb '$PG_STA_PGDATABASE'
    sudo -u postgres psql -X -tAc \"SELECT 1 FROM pg_extension WHERE extname='pg_sta'\" \
        -d '$PG_STA_PGDATABASE' | grep -q 1 \
        || sudo -u postgres psql -X -d '$PG_STA_PGDATABASE' -c 'CREATE EXTENSION pg_sta'
"

echo "==> running QA setup"
# The setup file is split into phases ("-- @phase N" markers) and every
# phase is executed in its own session.  A session boundary is required
# because PostgreSQL publishes the row-count deltas of a backend only when
# that backend goes idle or ends: an ANALYZE that shares a session with the
# DML it is meant to describe would be overwritten by the deferred flush.
PHASES=$(mktemp -d)
awk -v out="$PHASES" '
    /^--[[:space:]]*@phase[[:space:]]+[0-9]+/ {
        n = $3 + 0
        file = sprintf("%s/phase_%02d.sql", out, n)
        print > file
        next
    }
    {
        if (file == "")
            file = sprintf("%s/phase_00.sql", out)
        print > file
    }
' "$ROOT/test/qa_setup.sql"

for f in "$PHASES"/phase_*.sql; do
    [ -s "$f" ] || continue
    scp -q -i "$PG_STA_SSH_KEY" -P "$PG_STA_SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$f" "vagrant@$PG_STA_HOST:$WORKDIR/$(basename "$f")"
done

for f in "$PHASES"/phase_*.sql; do
    [ -s "$f" ] || continue
    name=$(basename "$f")
    echo "    -> $name"
    "${SSH[@]}" "vagrant@$PG_STA_HOST" "
        sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 -d '$PG_STA_PGDATABASE' -f '$WORKDIR/$name'
    " || { echo "!! QA setup failed in $name"; rm -rf "$PHASES"; exit 1; }
done
rm -rf "$PHASES"

echo "==> running QA assertions"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

"${SSH[@]}" "vagrant@$PG_STA_HOST" "
    sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 -d '$PG_STA_PGDATABASE' -f '$ASSERT'
" > "$OUT" 2>&1
RC=$?

if [ "$RC" -ne 0 ]; then
    echo "!! QA assertions aborted (psql exit $RC)"
    cat "$OUT"
    exit 1
fi

# The assertion report is emitted unaligned with '|' as the field separator
# so that the runner can parse it without depending on psql's table layout.
# In unaligned mode psql renders booleans as 't' / 'f'.
REPORT=$(grep -E '^[A-Za-z].*\|.*\|.*\|(t|f)$' "$OUT" || true)

TOTAL=$(grep -Eo 'TOTAL=[0-9]+' "$OUT" | tail -1 | cut -d= -f2)
PASSED=$(grep -Eo 'PASSED=[0-9]+' "$OUT" | tail -1 | cut -d= -f2)
FAILED=$(grep -Eo 'FAILED=[0-9]+' "$OUT" | tail -1 | cut -d= -f2)

echo
echo "==================== pg_sta QA report ===================="
if [ -n "$REPORT" ]; then
    printf '%-58s %-28s %-28s %s\n' "ASSERTION" "EXPECTED" "ACTUAL" "RESULT"
    printf '%.0s-' {1..130}; echo
    while IFS='|' read -r a e act r; do
        [ -z "${a:-}" ] && continue
        printf '%-58s %-28s %-28s %s\n' "$a" "$e" "$act" \
            "$( [ "$r" = "t" ] && echo PASS || echo FAIL )"
    done <<< "$REPORT"
fi
echo "--------------------------------------------------------"
printf 'total=%s passed=%s failed=%s\n' "${TOTAL:-?}" "${PASSED:-?}" "${FAILED:-?}"

if [ "${FAILED:-1}" != "0" ]; then
    echo "==> QA FAILED"
    exit 1
fi

echo "==> QA PASSED"
exit 0
