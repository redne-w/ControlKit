#!/bin/sh
# Exercise the experimental command boundary, not only the in-process resolver.
set -eu
if [ "${1:-}" = "--help" ] || [ "$#" -ne 1 ]; then
    printf 'Usage: sh Tools/discovery-check.sh <absolute-ControlKit-binary>\n'
    [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
binary=$1
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-discovery-check.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
trap 'exit 1' HUP INT TERM

field() {
    /usr/bin/plutil -extract "$1" raw -o - "$temporary/result.json"
}
run() {
    expected=$1
    shift
    status=0
    "$binary" probe discover "$@" >"$temporary/result.json" 2>"$temporary/stderr" || status=$?
    test "$status" -eq "$expected"
    test ! -s "$temporary/stderr"
}

run 0 --project "$repo" --xcode-project Probe/ControlKitProbe.xcodeproj \
    --scheme ControlKitProbe --configuration Debug
test "$(field ok)" = true
test "$(field report.validation)" = filesystem_only
test "$(field report.container.source.kind)" = explicit

mkdir -p "$temporary/repo/App.xcodeproj"
printf '// fixture\n' >"$temporary/repo/App.xcodeproj/project.pbxproj"
run 1 --project "$temporary/repo"
test "$(field error.code)" = configuration_missing
test "$(field report.requiredChoices.0)" = scheme

printf '%s\n' '{"name":"xcode build server","kind":"xcode",' \
    '"workspace":"App.xcodeproj/project.xcworkspace","scheme":"App"}' \
    >"$temporary/repo/buildServer.json"
run 0 --project "$temporary/repo" --configuration Debug
test "$(field report.container.source.kind)" = buildServer
test "$(field report.scheme.value)" = App

run 1 --project "$temporary/repo" --workspace Missing.xcworkspace --configuration Debug
test "$(field error.code)" = invalid_configuration
run 1 --project "$temporary/repo" --timeout nan
test "$(field error.code)" = invalid_configuration

printf 'Discovery CLI workflow passed.\n'
