#!/bin/sh
set -eu
if [ "${1:-}" = "--help" ] || [ "$#" -ne 1 ]; then
    printf 'Usage: sh Tools/skill-check.sh <ControlKit-binary>\n'
    [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
skill=plugins/ios/skills/ios-use-controlkit/SKILL.md
grep -Fqx 'name: ios-use-controlkit' "$skill"
grep -Fq 'Never replay a request whose completion is `unknown`.' "$skill"
grep -Fq 'ControlKit session recover' "$skill"
grep -Fq 'ControlKit session stop' "$skill"
for command in doctor setup run sim app session ui logs; do
    "$1" help "$command" >/dev/null
done
printf 'Agent skill contract passed.\n'
