#!/usr/bin/env bash
# Build the extension on the development VM.
#
#   scripts/build.sh            compile only
#   scripts/build.sh install    compile and install into the PostgreSQL tree
set -euo pipefail

PG_STA_HOST=${PG_STA_HOST:-127.0.0.1}
PG_STA_SSH_PORT=${PG_STA_SSH_PORT:-2201}
PG_STA_SSH_KEY=${PG_STA_SSH_KEY:-$HOME/.vagrant.d/insecure_private_key}
PG_STA_REMOTE=${PG_STA_REMOTE:-/home/vagrant/pg_sta}
PG_STA_PG_CONFIG=${PG_STA_PG_CONFIG:-/usr/pgsql-17/bin/pg_config}

TARGET="${1:-}"

if [ -n "$TARGET" ]; then
    CMD="sudo make PG_CONFIG='$PG_STA_PG_CONFIG' $TARGET"
else
    CMD="make PG_CONFIG='$PG_STA_PG_CONFIG'"
fi

echo "==> $CMD on vagrant@$PG_STA_HOST"
ssh -i "$PG_STA_SSH_KEY" -p "$PG_STA_SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "vagrant@$PG_STA_HOST" \
    "cd '$PG_STA_REMOTE' && $CMD"
