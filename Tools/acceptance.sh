#!/bin/sh
# Mutating local acceptance for the complete simulator-only MVP.
set -eu
if [ "${1:-}" = "--help" ] || [ "$#" -ne 3 ]; then
    printf 'Usage: sh Tools/acceptance.sh <ControlKit-binary> <dedicated-udid> <source-root>\n'
    printf 'Builds/installs/launches the fixture, runs UI checks, then stops and shuts down.\n'
    [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
binary=$1
device=$2
source=$3
runtime=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-acceptance.XXXXXX")
# Keep acceptance diagnostics out of the user's log. An already-running supervisor keeps
# writing where it started, so the checks below rely only on CLI-side records.
export CONTROLKIT_LOG_DIRECTORY="$runtime/logs"
session=
app_running=false
cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        # Keep command output and diagnostics for the failed step; credentials never reach them.
        kept=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-acceptance-failed.XXXXXX")
        cp -R "$runtime/." "$kept/" 2>/dev/null || true
        printf 'Acceptance failed (status %s). Outputs and logs: %s\n' "$status" "$kept" >&2
    fi
    if [ -n "$session" ]; then
        "$binary" session stop --session "$session" --json >/dev/null 2>&1 || true
    fi
    if [ "$app_running" = true ]; then
        "$binary" app terminate --device "$device" --bundle-id dev.controlkit.fixture \
            --json >/dev/null 2>&1 || true
    fi
    "$binary" sim shutdown --device "$device" --json >/dev/null 2>&1 || true
    rm -rf "$runtime"
}
trap cleanup EXIT HUP INT TERM

"$binary" doctor --project "$source" \
    --xcode-project Probe/ControlKitProbe.xcodeproj --scheme ControlKitProbe \
    --configuration Debug --json >"$runtime/doctor.json"
if grep -q '"severity":"error"' "$runtime/doctor.json"; then
    printf 'Doctor reported an acceptance-blocking finding.\n' >&2
    exit 1
fi

mkdir -p "$runtime/setup/App.xcodeproj"
printf '// acceptance fixture\n' >"$runtime/setup/App.xcodeproj/project.pbxproj"
"$binary" setup --project "$runtime/setup" --xcode-project App.xcodeproj \
    --scheme App --configuration Debug --profile-name acceptance \
    --write --non-interactive --yes --json >"$runtime/setup.json"
test -s "$runtime/setup/controlkit.json"

"$binary" run --project "$source" \
    --xcode-project Probe/ControlKitProbe.xcodeproj --scheme ControlKitProbe \
    --configuration Debug --product ControlKitFixture --device "$device" \
    --json >"$runtime/run.json"
session=$(/usr/bin/plutil -extract data.session.id raw -o - "$runtime/run.json")
app_running=true
generation=$(/usr/bin/plutil -extract data.session.generation raw -o - "$runtime/run.json")
grep -q '"session.start"' "$runtime/run.json"
# The window covers slow session starts: on iOS 27 the launch message can be over 30 s old here.
"$binary" app logs --device "$device" --bundle-id dev.controlkit.fixture \
    --since 120 --limit 512 --json >"$runtime/app-logs.json"
grep -q 'ControlKit fixture launched' "$runtime/app-logs.json"
if grep -q 'fixed-test-secret' "$runtime/app-logs.json"; then
    printf 'Application logs included secure fixture text.\n' >&2
    exit 1
fi

"$binary" ui inspect --session "$session" --generation "$generation" --json \
    >"$runtime/inspect.json"
grep -q '"identifier":"fixture.open"' "$runtime/inspect.json"
if grep -q 'fixed-test-secret' "$runtime/inspect.json"; then
    printf 'Secure field value was serialized.\n' >&2
    exit 1
fi
"$binary" ui tap --session "$session" --generation "$generation" \
    --id fixture.open --json >"$runtime/tap.json"
"$binary" ui screenshot --session "$session" --generation "$generation" \
    --output-path "$runtime/screen.png" --json >"$runtime/screenshot.json"
test -s "$runtime/screen.png"
"$binary" logs --session "$session" --json >"$runtime/logs.json"
grep -q 'command.finished' "$runtime/logs.json"
if grep -q 'fixed-test-secret' "$runtime/logs.json"; then
    printf 'Diagnostics included app text.\n' >&2
    exit 1
fi

grep -q '"event":"cli.response"' "$runtime/logs/controlkit.log"
grep -q '"operation":"ui.tap"' "$runtime/logs/controlkit.log"
if grep -rq 'fixed-test-secret' "$runtime/logs"; then
    printf 'Persistent diagnostics included secure fixture text.\n' >&2
    exit 1
fi

"$binary" session stop --session "$session" --json >"$runtime/stop.json"
session=
"$binary" app terminate --device "$device" --bundle-id dev.controlkit.fixture \
    --json >"$runtime/terminate.json"
app_running=false
"$binary" sim shutdown --device "$device" --json >"$runtime/shutdown.json"
printf 'Complete ControlKit acceptance passed on %s.\n' "$device"
