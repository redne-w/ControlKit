#!/bin/sh
# Live session scheduling, observation, interaction, uncertainty, and recovery checks.
set -eu
if [ "${1:-}" = "--help" ] || [ "$#" -ne 2 ]; then
    printf 'Usage: sh Tools/session-smoke.sh <ControlKit-binary> <dedicated-udid>\n'
    printf 'Boots and mutates that simulator, uses dev.controlkit.fixture, then shuts it down.\n'
    [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
binary=$1
device=$2
runtime=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-session-smoke.XXXXXX")
session=
cleanup() {
    if [ -n "$session" ]; then
        "$binary" session stop --session "$session" --json >/dev/null 2>&1 || true
    fi
    "$binary" probe sim shutdown --device "$device" >/dev/null 2>&1 || true
    rm -rf "$runtime"
}
trap cleanup EXIT HUP INT TERM

"$binary" probe sim boot --device "$device" >"$runtime/boot.json"
xcrun simctl terminate "$device" dev.controlkit.fixture >/dev/null 2>&1 || true
xcrun simctl install "$device" "$CONTROLKIT_PROBE_PRODUCTS/Debug-iphonesimulator/ControlKitFixture.app"
launched=$(xcrun simctl launch "$device" dev.controlkit.fixture)
pid_before=${launched##*: }
start_request=$(uuidgen)
"$binary" session start --device "$device" --app dev.controlkit.fixture \
    --request-id "$start_request" --json \
    >"$runtime/start.json"
session=$(/usr/bin/plutil -extract data.session.id raw -o - "$runtime/start.json")
"$binary" session start --device "$device" --app dev.controlkit.fixture \
    --request-id "$start_request" --json >"$runtime/start-duplicate.json"
test "$(/usr/bin/plutil -extract data.session.id raw -o - "$runtime/start-duplicate.json")" \
    = "$session"

"$binary" ui inspect --session "$session" --generation 1 --json >"$runtime/inspect.json"
grep -q '"identifier":"fixture.open"' "$runtime/inspect.json"
if grep -q 'fixed-test-secret' "$runtime/inspect.json"; then
    printf 'Secure field value was serialized.\n' >&2
    exit 1
fi
"$binary" ui tap --session "$session" --generation 1 --id fixture.open --json \
    >"$runtime/open.json"
"$binary" ui tap --session "$session" --generation 1 --id fixture.increment --json \
    >"$runtime/increment.json"
"$binary" ui find --session "$session" --generation 1 --type 49 --json \
    >"$runtime/find-fields.json"
snapshot=$(/usr/bin/plutil -extract data.ui.find.snapshotId raw -o - "$runtime/find-fields.json")
reference=$(
    /usr/bin/plutil -extract data.ui.find.matches.1.reference raw -o - "$runtime/find-fields.json"
)
"$binary" ui set-text --session "$session" --generation 1 \
    --snapshot "$snapshot" --ref "$reference" --text '/first' --json \
    >"$runtime/set-reference.json"
"$binary" ui find --session "$session" --generation 1 --type 49 --json \
    >"$runtime/find-coordinate.json"
snapshot=$(
    /usr/bin/plutil -extract data.ui.find.snapshotId raw -o - "$runtime/find-coordinate.json"
)
left=$(/usr/bin/plutil -extract data.ui.find.matches.1.frame.x raw -o - \
    "$runtime/find-coordinate.json")
top=$(/usr/bin/plutil -extract data.ui.find.matches.1.frame.y raw -o - \
    "$runtime/find-coordinate.json")
width=$(/usr/bin/plutil -extract data.ui.find.matches.1.frame.width raw -o - \
    "$runtime/find-coordinate.json")
height=$(/usr/bin/plutil -extract data.ui.find.matches.1.frame.height raw -o - \
    "$runtime/find-coordinate.json")
x=$(awk -v start="$left" -v size="$width" 'BEGIN { print start + size / 2 }')
y=$(awk -v start="$top" -v size="$height" 'BEGIN { print start + size / 2 }')
"$binary" ui set-text --session "$session" --generation 1 \
    --snapshot "$snapshot" --x "$x" --y "$y" --text '/second' --json \
    >"$runtime/set-coordinate.json"
"$binary" ui inspect --session "$session" --generation 1 --json \
    >"$runtime/inspect-set-text.json"
grep -q '"value":"/second"' "$runtime/inspect-set-text.json"
"$binary" ui type --session "$session" --generation 1 --id fixture.input \
    --text 'Hello café 👋' --json >"$runtime/type.json"
"$binary" ui tap --session "$session" --generation 1 --id fixture.dismiss --json \
    >"$runtime/dismiss.json"
"$binary" ui scroll --session "$session" --generation 1 --id fixture.scroll \
    --direction down --json >"$runtime/scroll.json"
"$binary" ui wait --session "$session" --generation 1 --id fixture.bottom \
    --state exists --json >"$runtime/wait.json"
"$binary" ui screenshot --session "$session" --generation 1 \
    --output-path "$runtime/screen.png" --json >"$runtime/screenshot.json"
test -s "$runtime/screen.png"

request=$(uuidgen)
"$binary" ui tap --session "$session" --generation 1 --label 'ControlKit fixture' --type 9 \
    --request-id "$request" --json >"$runtime/back.json"
"$binary" ui tap --session "$session" --generation 1 --label 'ControlKit fixture' --type 9 \
    --request-id "$request" --json >"$runtime/duplicate.json"
test "$(/usr/bin/plutil -extract data.ui.acknowledged raw -o - "$runtime/duplicate.json")" = true

"$binary" ui tap --session "$session" --generation 1 --id fixture.open --json \
    >"$runtime/reopen.json"
set +e
"$binary" ui tap --session "$session" --generation 1 --label 'ControlKit fixture' --type 9 \
    --fault-disconnect-after-dispatch --json >"$runtime/unknown.json"
status=$?
set -e
test "$status" -eq 4
test "$(/usr/bin/plutil -extract completion raw -o - "$runtime/unknown.json")" = unknown
"$binary" session recover --session "$session" --json >"$runtime/recover.json"
test "$(/usr/bin/plutil -extract data.session.state raw -o - "$runtime/recover.json")" \
    = needsInspection
set +e
"$binary" ui tap --session "$session" --generation 2 --id fixture.open --json \
    >"$runtime/blocked.json"
status=$?
set -e
test "$status" -eq 3
test "$(/usr/bin/plutil -extract error.code raw -o - "$runtime/blocked.json")" \
    = inspection_required
"$binary" ui inspect --session "$session" --generation 2 --json \
    >"$runtime/recovery-inspect.json"
"$binary" ui tap --session "$session" --generation 2 --id fixture.open --json \
    >"$runtime/post-recovery.json"
"$binary" session stop --session "$session" --json >"$runtime/stop.json"
session=
test "$(/usr/bin/plutil -extract data.session.state raw -o - "$runtime/stop.json")" = stopped
running=$(xcrun simctl launch "$device" dev.controlkit.fixture)
pid_after=${running##*: }
test "$pid_before" = "$pid_after"
"$binary" probe sim shutdown --device "$device" >"$runtime/shutdown.json"
printf 'Session/UI smoke passed; target app PID %s and data were retained.\n' "$pid_after"
