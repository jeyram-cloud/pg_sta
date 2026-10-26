#!/usr/bin/env bash
# Recreate the pg_sta extension in the development database.
#
# The extension ships a single base script (sql/pg_sta--0.1.1.sql).  During
# development that script changes constantly, so the simplest and most
# reliable way to pick up the new definition is to drop and recreate the
# extension.  Only ever run this against a scratch database.
#
#   scripts/reload.sh [database]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DB="${1:-${PG_STA_PGDATABASE:-pg_sta_qa}}"

"$HERE/sync.sh" >/dev/null
"$HERE/build.sh" install >/dev/null

{
    printf 'DROP EXTENSION IF EXISTS pg_sta CASCADE;\n'
    printf 'CREATE EXTENSION pg_sta;\n'
} | "$HERE/psql.sh" -d "$DB"

echo "pg_sta reloaded in $DB"
