#!/usr/bin/env bash
# Run the pg_regress suite against the development VM.
#
# pg_regress writes its results next to the input files, so the source tree
# has to be writable by the database user.  The tree that is synced into the
# VM is owned by "vagrant", so the suite is executed from a throw-away copy
# owned by "postgres" instead.  Nothing in the working tree is modified.
#
#   scripts/installcheck.sh              run the suite
#   scripts/installcheck.sh --record     write expected/pg_sta.out from the run
#
# The "results" directory and the diff file are copied back to the host so
# that a failing run can be inspected.
#
# The suite runs on the VM over SSH when the script is started on the
# workstation, and in a local copy of the tree when it is started on the VM.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=scripts/pg_sta_conn.sh
. "$HERE/pg_sta_conn.sh"

PG_STA_REMOTE=${PG_STA_REMOTE:-/home/vagrant/pg_sta}
PG_STA_PG_CONFIG=${PG_STA_PG_CONFIG:-/usr/pgsql-17/bin/pg_config}
PG_STA_TESTDB=${PG_STA_TESTDB:-pg_sta_regress}
PG_STA_WORKDIR=${PG_STA_WORKDIR:-/tmp/pg_sta_installcheck}

RECORD=0
for arg in "$@"; do
    case "$arg" in
        --record) RECORD=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# A diff file from a previous run is worse than no diff file at all: it
# looks like the result of this run.  Remove it before starting.
rm -f "$ROOT/regression.diffs"

pg_sta_resolve_mode

# The tree that carries the test files: the synced copy on the VM, or the
# local tree when the suite runs on the VM itself.
TREE=$(pg_sta_target_tree)
AS_PG=$(pg_sta_postgres_prefix)

if [ "$PG_STA_MODE" = "ssh" ]; then
    "$HERE/sync.sh" >/dev/null
    echo "==> running the regression suite on vagrant@$PG_STA_HOST:$PG_STA_SSH_PORT"
else
    echo "==> running the regression suite locally in $PG_STA_WORKDIR"
fi

CMD="set -e
rm -rf '$PG_STA_WORKDIR' 2>/dev/null || sudo rm -rf '$PG_STA_WORKDIR' 2>/dev/null || true
mkdir -p '$PG_STA_WORKDIR'
cp -a '$TREE/.' '$PG_STA_WORKDIR/'
sudo chown -R postgres:postgres '$PG_STA_WORKDIR' 2>/dev/null || true
$AS_PG psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$PG_STA_TESTDB'\" | grep -q 1 \
    || $AS_PG createdb '$PG_STA_TESTDB'
cd '$PG_STA_WORKDIR'
$AS_PG env PATH=/usr/pgsql-17/bin:\$PATH PGHOST=/var/run/postgresql \
    make installcheck PG_CONFIG='$PG_STA_PG_CONFIG' \
    REGRESS_OPTS='--dbname=$PG_STA_TESTDB' 2>&1 | tail -40
exit \${PIPESTATUS[0]}"

pg_sta_ssh "$CMD" && RC=0 || RC=$?

# Copy the artefacts back so that a failure can be inspected on the host.
pg_sta_pull "$PG_STA_WORKDIR/results/pg_sta.out" "$ROOT/expected/pg_sta.out.actual" 2>/dev/null || true

# pg_regress removes regression.diffs when the suite passes, so a missing
# file means "no differences".  Copy it back only when it exists.
if pg_sta_target_exists "$PG_STA_WORKDIR/regression.diffs"; then
    pg_sta_pull "$PG_STA_WORKDIR/regression.diffs" "$ROOT/regression.diffs" 2>/dev/null || true
else
    echo "==> no differences (regression.diffs not produced)"
fi

if [ "$RECORD" = "1" ] && [ -f "$ROOT/expected/pg_sta.out.actual" ]; then
    mv "$ROOT/expected/pg_sta.out.actual" "$ROOT/expected/pg_sta.out"
    echo "==> expected/pg_sta.out updated"
fi

rm -f "$ROOT/expected/pg_sta.out.actual"

exit "$RC"
