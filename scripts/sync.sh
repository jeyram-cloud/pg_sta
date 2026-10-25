#!/usr/bin/env bash
# Copy the pg_sta source tree to the development VM.
#
# On the workstation the tree is pushed over SSH to PG_STA_REMOTE.  On the VM
# itself the tree is already the target tree, so nothing is copied.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/pg_sta_conn.sh
. "$HERE/pg_sta_conn.sh"

PG_STA_REMOTE=${PG_STA_REMOTE:-/home/vagrant/pg_sta}
PG_STA_SRC=${PG_STA_SRC:-$(cd "$HERE/.." && pwd)}

pg_sta_resolve_mode

if [ "$PG_STA_MODE" = "local" ]; then
    echo "==> local mode: $PG_STA_SRC is already the target tree"
    exit 0
fi

echo "==> rsync $PG_STA_SRC/ -> vagrant@$PG_STA_HOST:$PG_STA_REMOTE/ (port $PG_STA_SSH_PORT)"
rsync -az --delete --delete-excluded \
  --exclude '.git/' \
  --exclude '*.o' --exclude '*.so' --exclude '*.bc' \
  --exclude '.deps/' --exclude 'tmp_check/' \
  --exclude 'regression.diffs' --exclude 'regression.out' \
  -e "ssh -i $PG_STA_SSH_KEY -p $PG_STA_SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  "$PG_STA_SRC/" "vagrant@$PG_STA_HOST:$PG_STA_REMOTE/"
