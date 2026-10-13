#!/bin/sh
# Called by Just; also usable directly against any already-built ControlKit binary.
set -eu
if [ "${1:-}" = "--help" ] || [ "$#" -ne 1 ]; then
    printf 'Usage: sh Tools/help-check.sh <ControlKit-binary>\n'
    [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
binary=$1
check_help() {
    named=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help "$@")
    flagged=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" "$@" --help)
    test "$named" = "$flagged"
    case "$named" in *"USAGE:"*"OPTIONS:"*) ;; *) exit 1 ;; esac
    printf 'Help contract passed: ControlKit %s\n' "$*"
}
check_help
check_help probe
check_help probe request
check_help probe discover
check_help probe sim
check_help probe sim list
check_help probe sim create
check_help probe sim boot
check_help probe sim shutdown
check_help probe helper-check
check_help session
check_help session start
check_help session list
check_help session status
check_help session recover
check_help session stop
check_help ui
check_help ui inspect
check_help ui find
check_help ui screenshot
check_help ui tap
check_help ui type
check_help ui set-text
check_help ui swipe
check_help ui scroll
check_help ui wait
check_help ui system-alert
check_help ui system-alert inspect
check_help ui system-alert tap
check_help sim
check_help sim list
check_help sim create
check_help sim boot
check_help sim shutdown
check_help app
check_help app build
check_help app install
check_help app launch
check_help app terminate
check_help app logs
check_help app crashes
check_help doctor
check_help setup
check_help run
check_help logs
check_help report
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help report)
case "$leaf" in *"Library/Logs/ControlKit"*"--output-directory"*"--files-only"*) ;; *) exit 1 ;; esac
version=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" --version)
case "$version" in [0-9]*.[0-9]*.[0-9]*" ("*")") ;; *) exit 1 ;; esac
printf 'Version contract passed: %s\n' "$version"
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help probe request)
case "$leaf" in *"Examples:"*"--timeout"*"(default:"*) ;; *) exit 1 ;; esac
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help probe discover)
case "$leaf" in *"Examples:"*"--profile"*"--timeout"*"(default:"*) ;; *) exit 1 ;; esac
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help probe helper-check)
case "$leaf" in *"Example:"*"--device"*"--source"*"--cache"*) ;; *) exit 1 ;; esac
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help session recover)
case "$leaf" in *"Never replays"*"--session"*"--request-id"*) ;; *) exit 1 ;; esac
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help ui tap)
case "$leaf" in *"--session"*"--generation"*"--request-id"*"--id"*"--ref"*"--timeout"*) ;; *) exit 1 ;; esac
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help run)
case "$leaf" in *"Build scripts"*"--device"*"--app-path"*"--request-id"*"--timeout"*) ;; *) exit 1 ;; esac
leaf=$(env -u CONTROLKIT_PROBE_TOKEN "$binary" help setup)
case "$leaf" in *"buildServer.json"*"--write"*"--yes"*"--non-interactive"*) ;; *) exit 1 ;; esac
