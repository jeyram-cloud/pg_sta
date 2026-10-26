#!/usr/bin/env bash
#
# load_benchmark.sh -- build the pg_sta benchmark and prove the advisor on it.
#
# Creates N tables (default 20) with M rows each (default 1,000,000),
# runs a workload of ten statements that are written the way real
# application SQL tends to be written, and then asks the advisor for its
# opinion.  The three things that have to come back are:
#
#   * index candidates        -- sta.index_advice()
#   * SQL rewrites            -- sta.rewrite_advice()
#   * a plan that can be pinned -- sta.plan_advice_string() / the stash
#
# It works both on the workstation (over SSH) and on the database host
# (with the local psql client); the transport is resolved automatically.
#
# Usage:
#   load_benchmark.sh [--database DB] [--tables N] [--rows N]
#                     [--iterations N] [--no-reset-stats] [--analyze-all]
#
#   --database DB     the target database              (default: $PG_STA_PGDATABASE)
#   --tables N        number of tables to create       (default: 20)
#   --rows N          rows per table                   (default: 1000000)
#   --iterations N    executions per workload statement(default: 20)
#   --no-reset-stats  keep the existing pg_stat_statements entries
#   --analyze-all     analyze every table; by default the last two tables
#                     are left un-analysed, so that the statistics advisor
#                     has a subject as well
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# shellcheck source=scripts/pg_sta_conn.sh
. "$HERE/pg_sta_conn.sh"

DB="${PG_STA_PGDATABASE}"
TABLES=20
ROWS=1000000
ITERATIONS=20
RESET_STATS=1
ANALYZE_ALL=0

die() { echo "load_benchmark.sh: $*" >&2; exit 1; }
note() { echo "load_benchmark.sh: $*" >&2; }

usage() {
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--database)    DB="$2"; shift 2 ;;
        --tables)        TABLES="$2"; shift 2 ;;
        --rows)          ROWS="$2"; shift 2 ;;
        --iterations)    ITERATIONS="$2"; shift 2 ;;
        --no-reset-stats) RESET_STATS=0; shift ;;
        --analyze-all)   ANALYZE_ALL=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "unknown option: $1" ;;
    esac
done

for v in "$TABLES" "$ROWS" "$ITERATIONS"; do
    case "$v" in
        ''|*[!0-9]*) die "the counts must be positive numbers" ;;
    esac
    [ "$v" -ge 1 ] || die "the counts must be positive numbers"
done

DATA_SQL="$ROOT/sql/benchmark_data.sql"
WORK_SQL="$ROOT/sql/benchmark_workload.sql"
ANALYZE_SQL="$ROOT/sql/benchmark_analyze.sql"
[ -f "$DATA_SQL" ] || die "cannot find $DATA_SQL"
[ -f "$WORK_SQL" ] || die "cannot find $WORK_SQL"
[ -f "$ANALYZE_SQL" ] || die "cannot find $ANALYZE_SQL"

pg_sta_resolve_mode

note "target database: $DB (transport: $PG_STA_MODE)"
note "$TABLES tables x $ROWS rows, $ITERATIONS iterations per statement"

# Run a SQL file, prefixed by session settings, in one session.  The
# connection helper feeds psql from stdin, which works the same over SSH
# (the file is piped through the ssh channel) and locally.
run_file() {
    local file="$1"; shift
    {
        for stmt in "$@"; do
            printf '%s\n' "$stmt"
        done
        cat "$file"
    } | pg_sta_psql "$DB" "-q"
}

# --------------------------------------------------------------------------
# 1. the extensions
# --------------------------------------------------------------------------
printf '%s\n' "CREATE EXTENSION IF NOT EXISTS pg_sta;" \
    | pg_sta_psql "$DB" "-q" \
    || die "could not create the pg_sta extension in '$DB'"

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
# 2. the data
# --------------------------------------------------------------------------
note "creating the benchmark tables (this takes a while)"
run_file "$DATA_SQL" \
    "SET pg_sta.bench_tables = '$TABLES';" \
    "SET pg_sta.bench_rows = '$ROWS';" \
    "SET synchronous_commit = off;" \
    "SET maintenance_work_mem = '256MB';" \
    "SET work_mem = '32MB';" >/dev/null \
    || die "could not create the benchmark tables"

# The statistics have to be right, otherwise every plan estimate is wrong
# and the plan advice describes a plan that does not exist.  The last two
# tables are left alone, so that the statistics advisor has a subject.
if [ "$ANALYZE_ALL" -eq 1 ]; then
    SKIP=0
else
    SKIP=2
    if [ "$TABLES" -lt 3 ]; then
        SKIP=0
    fi
fi
note "analyzing every table except the last $SKIP"
run_file "$ANALYZE_SQL" \
    "SET pg_sta.bench_skip_analyze = '$SKIP';" >/dev/null \
    || die "could not analyze the benchmark tables"

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

    note "running the benchmark workload ($ITERATIONS iterations per statement)"
    run_file "$WORK_SQL" \
        "SET pg_sta.bench_iterations = '$ITERATIONS';" >/dev/null \
        || die "the benchmark workload failed"
else
    note "skipping the workload"
fi

# --------------------------------------------------------------------------
# 4. the summary
# --------------------------------------------------------------------------
note "collecting a snapshot"
printf '%s\n' "SELECT * FROM sta.collect();" \
    | pg_sta_psql "$DB" "-q" >/dev/null || die "could not collect a snapshot"

printf '%s\n' \
    "SELECT 'tables:            ' || count(*) FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname LIKE 'bench\_%' AND c.relkind = 'r';" \
    "SELECT 'rows:              ' || sum(n_live_tup) FROM pg_stat_user_tables
      WHERE relname LIKE 'bench\_%';" \
    "SELECT 'pg_stat_statements:' || count(*) FROM pg_stat_statements;" \
    | pg_sta_psql "$DB" "-q -A -t" || true

cat >&2 <<'MSG'

The benchmark is ready.  Try:

  # 1. the index candidates
  pg_sta_ctl --database <db> index "SELECT * FROM bench_01 WHERE customer_id = 42"

  # 2. the SQL rewrites
  pg_sta_ctl --database <db> rewrite "SELECT * FROM bench_01 WHERE customer_id = 42"

  # 3. the plan that can be pinned
  pg_sta_ctl --database <db> plan-advice "SELECT * FROM bench_01 WHERE customer_id = 42"

  # 4. everything the advisor found
  pg_sta_ctl --database <db> report
MSG
