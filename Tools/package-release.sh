#!/bin/bash
# Lays out bin/ControlKit and share/ControlKit under a prefix. Shared by local installs and
# GitHub releases so the installed file list cannot drift between them.
set -euo pipefail
export LC_ALL=C

if [[ ${1:-} = --help || $# -ne 2 ]]; then
    printf 'Usage: bash Tools/package-release.sh <built-ControlKit> <prefix>\n'
    printf 'Installs <prefix>/bin/ControlKit, helper sources, the agent skill, and build-info.\n'
    [[ ${1:-} = --help ]] && exit 0
    exit 2
fi
binary=$1
prefix=$2
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
share="$prefix/share/ControlKit"

install -d "$prefix/bin"
install -m 755 "$binary" "$prefix/bin/ControlKit"
install -d -m 755 \
    "$share/Helper/ControlKitRuntime.xcodeproj/xcshareddata/xcschemes" \
    "$share/Sources/ControlKitWire" \
    "$share/skills/ios-use-controlkit"
install -m 644 \
    "$source_root/Helper/RuntimeAutomation.swift" \
    "$source_root/Helper/RuntimeSnapshot.swift" \
    "$source_root/Helper/RuntimeTests.swift" \
    "$share/Helper/"
install -m 644 \
    "$source_root/Helper/ControlKitRuntime.xcodeproj/project.pbxproj" \
    "$share/Helper/ControlKitRuntime.xcodeproj/"
install -m 644 \
    "$source_root/Helper/ControlKitRuntime.xcodeproj/xcshareddata/xcschemes/ControlKitRuntime.xcscheme" \
    "$share/Helper/ControlKitRuntime.xcodeproj/xcshareddata/xcschemes/"
install -m 644 "$source_root"/Sources/ControlKitWire/*.swift "$share/Sources/ControlKitWire/"
install -m 644 \
    "$source_root/plugins/ios/skills/ios-use-controlkit/SKILL.md" \
    "$share/skills/ios-use-controlkit/"

# ControlKit --version and every diagnostic log line report this. A release tag gives "v1.2.3";
# local builds give e.g. "v1.2.3-4-gabc1234-dirty", or a bare commit before the first tag.
if ! version=$(git -C "$source_root" describe --tags --always --dirty 2>/dev/null); then
    version=unknown
fi
printf '%s\n' "$version" > "$share/build-info"
chmod 644 "$share/build-info"
