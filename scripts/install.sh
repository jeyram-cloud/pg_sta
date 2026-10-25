#!/usr/bin/env bash
# Build and install the extension into the PostgreSQL installation on the VM.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$HERE/sync.sh"
"$HERE/build.sh" install
