#!/bin/sh
set -eu
if [ "${1:-}" = "--help" ] || [ "$#" -ne 4 ]; then
    printf 'Usage: sh Tools/acceptance-soak.sh <ControlKit> <udid> <source-root> <rounds:1-3>\n'
    [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
case "$4" in 1|2|3) ;; *) printf 'Rounds must be 1, 2, or 3.\n' >&2; exit 2 ;; esac
round=1
while [ "$round" -le "$4" ]; do
    printf 'Acceptance round %s/%s\n' "$round" "$4"
    sh Tools/acceptance.sh "$1" "$2" "$3"
    round=$((round + 1))
done
