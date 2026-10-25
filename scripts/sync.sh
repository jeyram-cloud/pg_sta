#!/usr/bin/env bash
# Copy the pg_sta source tree to the development VM.
set -euo pipefail

PG_STA_HOST=${PG_STA_HOST:-127.0.0.1}
PG_STA_SSH_PORT=${PG_STA_SSH_PORT:-2201}
PG_STA_SSH_KEY=${PG_STA_SSH_KEY:-$HOME/.vagrant.d/insecure_private_key}
PG_STA_REMOTE=${PG_STA_REMOTE:-/home/vagrant/pg_sta}
PG_STA_SRC=${PG_STA_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

echo "==> rsync $PG_STA_SRC/ -> vagrant@$PG_STA_HOST:$PG_STA_REMOTE/ (port $PG_STA_SSH_PORT)"
rsync -az --delete --delete-excluded \
  --exclude '.git/' \
  --exclude '*.o' --exclude '*.so' --exclude '*.bc' \
  --exclude '.deps/' --exclude 'tmp_check/' \
  --exclude 'regression.diffs' --exclude 'regression.out' \
  -e "ssh -i $PG_STA_SSH_KEY -p $PG_STA_SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  "$PG_STA_SRC/" "vagrant@$PG_STA_HOST:$PG_STA_REMOTE/"
