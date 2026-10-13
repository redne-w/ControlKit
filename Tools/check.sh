#!/bin/sh
# Backward-compatible entrypoint. The justfile is the single source of development recipes.
set -eu

cd "$(dirname "$0")/.."
if [ "${1:-}" = "--help" ]; then
    printf 'Usage: sh Tools/check.sh\nRuns just check using the current DEVELOPER_DIR.\n'
    exit 0
fi
test "$#" -eq 0
exec just check
