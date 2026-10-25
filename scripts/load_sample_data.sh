#!/usr/bin/env bash
#
# load_sample_data.sh -- load the pg_sta sample data and generate a workload.
#
# The examples in README.md and in docs/usage.md use two tables, customers
# and orders.  This script creates them, fills them with a deterministic
# data set and then executes a set of representative statements, so that
# pg_stat_statements holds a workload and the advisor has something to
# report.
#
# It works both on the workstation (over SSH) and on the database host
# (with the local psql client); the transport is resolved automatically.
#
# Usage:
#   load_sample_data.sh [--database DB] [--iterations N] [--analyze-all]
#                        [--no-reset-stats] [--force]
#
#   --database DB     the target database              (default: $PG_STA_PGDATABASE)
#   --iterations N    executions per workload statement (default: 120)
#   --analyze-all     also ANALYZE orders; by default only customers is
#                     analyzed, so that the "never analyzed" finding has a
#                     subject
#   --no-reset-stats  keep the existing pg_stat_statements entries instead
#                     of resetting them
#   --force           drop the sample tables before loading them.  Only
#                     tables that carry the marker comment "pg_sta sample
#                     data" are dropped.
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# shellcheck source=scripts/pg_sta_conn.sh
. "$HERE/pg_sta_conn.sh"

DB="${PG_STA_PGDATABASE}"
ITERATIONS=120
ANALYZE_ALL=0
RESET_STATS=1
FORCE=0

die() { echo "load_sample_data.sh: $*" >&2; exit 1; }
note() { echo "load_sample_data.sh: $*" >&2; }

usage() {
    sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--database)    DB="$2"; shift 2 ;;
        --iterations)    ITERATIONS="$2"; shift 2 ;;
        --analyze-all)   ANALYZE_ALL=1; shift ;;
        --no-reset-stats) RESET_STATS=0; shift ;;
        --force)         FORCE=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "unknown option: $1" ;;
    esac
done

case "$ITERATIONS" in
    ''|*[!0-9]*) die "--iterations needs a positive number" ;;
esac
[ "$ITERATIONS" -ge 1 ] || die "--iterations needs a positive number"

DATA_SQL="$ROOT/sql/sample_data.sql"
WORK_SQL="$ROOT/sql/sample_workload.sql"
[ -f "$DATA_SQL" ] || die "cannot find $DATA_SQL"
[ -f "$WORK_SQL" ] || die "cannot find $WORK_SQL"

pg_sta_resolve_mode

note "target database: $DB (transport: $PG_STA_MODE)"

# --------------------------------------------------------------------------
# 1. the extensions
# --------------------------------------------------------------------------
printf '%s\n' "CREATE EXTENSION IF NOT EXISTS pg_sta;" \
    | pg_sta_psql "$DB" "-q" \
    || die "could not create the pg_sta extension in '$DB'"

# pg_stat_statements only records anything when it is preloaded.
PRELOAD=$(printf '%s\n' "SHOW shared_preload_libraries;" \
          | pg_sta_psql "$DB" "-q -A -t" 2>/dev/null | tr -d '[:space:]')
HAS_PGSS=0
case "$PRELOAD" in
    *pg_stat_statements*) HAS_PGSS=1 ;;
esac

if [ "$HAS_PGSS" -eq 1 ]; then
    printf '%s\n' "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" \
        | pg_sta_psql "$DB" "-q" \
        || die "could not create the pg_stat_statements extension in '$DB'"
else
    note "pg_stat_statements is not in shared_preload_libraries;"
    note "the workload cannot be recorded; add it and restart the server"
fi

# --------------------------------------------------------------------------
# 2. the sample tables
# --------------------------------------------------------------------------
if [ "$FORCE" -eq 1 ]; then
    note "dropping the existing pg_sta sample tables"
    pg_sta_psql "$DB" "-q" <<'SQL' || die "could not drop the sample tables"
DO $pg_sta_drop$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND c.relname IN ('customers', 'orders')
           AND c.relkind = 'r'
           AND coalesce(obj_description(c.oid, 'pg_class'), '') LIKE 'pg_sta sample data%'
    LOOP
        EXECUTE format('DROP TABLE public.%I', r.relname);
    END LOOP;
END
$pg_sta_drop$;
SQL
fi

note "loading the sample tables"
pg_sta_psql "$DB" "-q" < "$DATA_SQL" || die "could not load the sample data"

# customers is analyzed, orders is not: that gives the statistics advice a
# subject.  --analyze-all analyzes both.
if [ "$ANALYZE_ALL" -eq 1 ]; then
    printf '%s\n' "ANALYZE public.customers;" "ANALYZE public.orders;" \
        | pg_sta_psql "$DB" "-q" || die "could not analyze the sample tables"
else
    printf '%s\n' "ANALYZE public.customers;" \
        | pg_sta_psql "$DB" "-q" || die "could not analyze the sample tables"
fi

# --------------------------------------------------------------------------
# 3. the workload
# --------------------------------------------------------------------------
if [ "$HAS_PGSS" -eq 1 ]; then
    if [ "$RESET_STATS" -eq 1 ]; then
        note "resetting pg_stat_statements"
        printf '%s\n' "SELECT pg_stat_statements_reset();" \
            | pg_sta_psql "$DB" "-q -A -t" >/dev/null 2>&1 \
            || note "could not reset pg_stat_statements; continuing"
    fi

    note "running the sample workload ($ITERATIONS iterations per statement)"
    pg_sta_psql "$DB" "-q -v iterations=$ITERATIONS" < "$WORK_SQL" \
        || die "the sample workload failed"
else
    note "skipping the workload"
fi

# --------------------------------------------------------------------------
# 4. the summary
# --------------------------------------------------------------------------
printf '%s\n' \
    "SELECT 'customers:                 ' || count(*) FROM public.customers;" \
    "SELECT 'orders:                    ' || count(*) FROM public.orders;" \
    | pg_sta_psql "$DB" "-q -A -t" || true

if [ "$HAS_PGSS" -eq 1 ]; then
    printf '%s\n' \
        "SELECT 'pg_stat_statements rows:  ' || count(*) FROM pg_stat_statements;" \
        | pg_sta_psql "$DB" "-q -A -t" || true
fi

cat >&2 <<'MSG'

The sample data is ready.  Try:

  pg_sta_ctl --database <db> collect
  pg_sta_ctl --database <db> report
  pg_sta_ctl --database <db> index "SELECT * FROM orders WHERE customer_id = 42"
MSG
