#!/bin/sh
set -eu
if [ "${1:-}" = "--help" ] || [ "$#" -ne 4 ]; then
    printf 'Usage: sh Tools/runtime-smoke.sh <ControlKit> <dedicated-udid> <source> <cache>\n'
    printf 'Boots, verifies graceful/cache-reused/disconnected helpers, then shuts down this device.\n'
    [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
binary=$1
device=$2
source=$3
cache=$4
"$binary" probe sim boot --device "$device"
"$binary" probe helper-check --device "$device" --source "$source" --cache "$cache"
"$binary" probe helper-check --device "$device" --source "$source" --cache "$cache" \
    --disconnect-after-ping
# Do not bypass a retained ownership fence if an earlier operation failed.
"$binary" probe sim shutdown --device "$device"
