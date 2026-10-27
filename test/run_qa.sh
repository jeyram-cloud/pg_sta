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
# The suite runs on the development VM over SSH when it is started on the
# workstation, and locally when it is started on the VM itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# The QA suite has a database of its own.  The default is set before the
# connection helper is sourced, because the helper carries a default of its
# own ("postgres"), which would otherwise win.
PG_STA_PGDATABASE=${PG_STA_PGDATABASE:-pg_sta_qa}

# shellcheck source=../scripts/pg_sta_conn.sh
. "$ROOT/scripts/pg_sta_conn.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        -d) PG_STA_PGDATABASE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

pg_sta_resolve_mode

AS_PG=$(pg_sta_postgres_prefix)

# -------------------------------------------------------------------------
# Static analysis of the extension scripts
#
# The SQL of the advisory engine is PL/pgSQL, and PL/pgSQL bodies are not
# parsed when the extension is created.  A wrong number of arguments in a
# format() call or an unbalanced parenthesis is therefore invisible until
# the statement is executed for the first time.  The linter models the
# PostgreSQL lexer and catches those defects before the extension is even
# installed, so the QA suite can never run against a broken script.
# -------------------------------------------------------------------------
echo "==> linting the extension scripts"
if [ -f "$ROOT/scripts/lint_sql.py" ]; then
    # The version comes from the control file, so that the linter always
    # checks the scripts that are about to be installed.
    PG_STA_EXTVERSION=$(sed -n "s/^default_version *= *'\([^']*\)'.*/\1/p" \
        "$ROOT/pg_sta.control")
    LINT_OUT=$(python3 "$ROOT/scripts/lint_sql.py" \
        "$ROOT/sql/pg_sta--$PG_STA_EXTVERSION.sql" \
        "$ROOT/sql/pg_sta--0.1.0--$PG_STA_EXTVERSION.sql" \
        "$ROOT/sql/pg_sta--0.1.1--$PG_STA_EXTVERSION.sql" \
        "$ROOT/sql/pg_sta--0.1.2--$PG_STA_EXTVERSION.sql" \
        "$ROOT/sql/pg_sta--0.1.3--$PG_STA_EXTVERSION.sql" \
        "$ROOT/sql/pg_sta--0.1.4--$PG_STA_EXTVERSION.sql" \
        "$ROOT/sql/pg_sta--$PG_STA_EXTVERSION--0.1.4.sql" 2>&1)
    if [ $? -ne 0 ]; then
        echo "$LINT_OUT"
        echo "!! the extension scripts do not pass the linter"
        exit 1
    fi
    echo "$LINT_OUT"
else
    echo "    (scripts/lint_sql.py not found, skipping)"
fi

# The QA files are staged in a work directory because the source tree may
# not be readable by the postgres user.
WORKDIR=${PG_STA_WORKDIR:-/tmp/pg_sta_qa_run}
SETUP="$WORKDIR/qa_setup.sql"
ASSERT="$WORKDIR/qa_assertions.sql"

if [ "$PG_STA_MODE" = "ssh" ]; then
    echo "==> staging QA files to $PG_STA_HOST:$WORKDIR"
else
    echo "==> staging QA files in $WORKDIR"
fi

pg_sta_ssh "mkdir -p '$WORKDIR' && chmod 755 '$WORKDIR'"
pg_sta_push "$ROOT/test/qa_setup.sql"      "$SETUP"
pg_sta_push "$ROOT/test/qa_assertions.sql" "$ASSERT"
# The files have to be readable by the postgres user on the target.
pg_sta_ssh "chmod 644 '$SETUP' '$ASSERT' 2>/dev/null || true"

echo "==> ensuring database '$PG_STA_PGDATABASE' and extension exist"
# The extension is dropped and created again, so that the QA run always
# tests the SQL that was just installed and never a stale copy of it.
pg_sta_ssh "
    set -e
    $AS_PG psql -X -tAc \"SELECT 1 FROM pg_database WHERE datname='$PG_STA_PGDATABASE'\" \
        | grep -q 1 || $AS_PG createdb '$PG_STA_PGDATABASE'
    $AS_PG psql -X -q -d '$PG_STA_PGDATABASE' -c 'DROP EXTENSION IF EXISTS pg_sta CASCADE'
    $AS_PG psql -X -q -d '$PG_STA_PGDATABASE' -c 'CREATE EXTENSION pg_sta'
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
    pg_sta_push "$f" "$WORKDIR/$(basename "$f")"
done

for f in "$PHASES"/phase_*.sql; do
    [ -s "$f" ] || continue
    name=$(basename "$f")
    echo "    -> $name"
    pg_sta_ssh "$AS_PG psql -X -q -v ON_ERROR_STOP=1 -d '$PG_STA_PGDATABASE' -f '$WORKDIR/$name'" \
        || { echo "!! QA setup failed in $name"; rm -rf "$PHASES"; exit 1; }
done
rm -rf "$PHASES"

echo "==> running QA assertions"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

pg_sta_ssh "$AS_PG psql -X -q -v ON_ERROR_STOP=1 -d '$PG_STA_PGDATABASE' -f '$ASSERT'" > "$OUT" 2>&1
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
