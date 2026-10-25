#!/usr/bin/env bash
# Build the extension on the development VM.
#
#   scripts/build.sh            compile only
#   scripts/build.sh install    compile and install into the PostgreSQL tree
#
# On the workstation the build runs on the VM over SSH; on the VM itself it
# runs in the local source tree.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/pg_sta_conn.sh
. "$HERE/pg_sta_conn.sh"

PG_STA_REMOTE=${PG_STA_REMOTE:-/home/vagrant/pg_sta}
PG_STA_PG_CONFIG=${PG_STA_PG_CONFIG:-/usr/pgsql-17/bin/pg_config}

TARGET="${1:-}"

if [ -n "$TARGET" ]; then
    CMD="sudo make PG_CONFIG='$PG_STA_PG_CONFIG' $TARGET"
else
    CMD="make PG_CONFIG='$PG_STA_PG_CONFIG'"
fi

pg_sta_resolve_mode

if [ "$PG_STA_MODE" = "local" ]; then
    # "make install" writes into the PostgreSQL tree, which needs root.
    if [ "$(id -u)" != "0" ] && ! sudo -n true 2>/dev/null; then
        pg_sta_note "'make ${TARGET:-}' needs root privileges and 'sudo' is not usable for the current user"
        pg_sta_note "run it as root, or as a user with passwordless sudo (for example 'vagrant')"
        exit 1
    fi
    echo "==> $CMD in $HERE/.. (local mode)"
    (cd "$HERE/.." && eval "$CMD")
    exit $?
fi

echo "==> $CMD on vagrant@$PG_STA_HOST"
ssh -i "$PG_STA_SSH_KEY" -p "$PG_STA_SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "vagrant@$PG_STA_HOST" \
    "cd '$PG_STA_REMOTE' && $CMD"
