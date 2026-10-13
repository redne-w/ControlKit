set positional-arguments
set shell := ["sh", "-eu", "-c"]

# Honor DEVELOPER_DIR and never change xcode-select. Outputs are separated per Xcode build.
toolchain := `xcrun xcodebuild -version | awk '/^Build version /{print $3;ok=1}END{exit !ok}'`
build_root := justfile_directory() / ".build/toolchains" / toolchain
swift_build := build_root / "swift"
cli := swift_build / "debug/ControlKit"
export CONTROLKIT_SOURCE_ROOT := justfile_directory()
export CONTROLKIT_PROBE_CLI := cli
export CONTROLKIT_PROBE_PRODUCTS := build_root / "xcode/Build/Products"
# Development runs must not fill the real ~/Library/Logs/ControlKit.
export CONTROLKIT_LOG_DIRECTORY := build_root / "logs"

# List recipes.
default:
    @just --list --unsorted

# Build the CLI (debug or release).
build configuration="debug":
    @case "$1" in debug|release) ;; *) printf 'Use debug or release.\n' >&2; exit 2 ;; esac
    xcrun swift build --scratch-path {{quote(swift_build)}} -c "$1" -Xswiftc -warnings-as-errors >&2

# Run unit tests.
test:
    xcrun swift test --scratch-path {{quote(swift_build)}} -Xswiftc -warnings-as-errors

# Format Swift sources in place.
format:
    xcrun swift-format format --in-place --recursive \
        Package.swift Sources Tests Probe/Helper Probe/Fixture Helper Tools Specification

# Run every check that does not need a simulator.
check: build
    bash Tools/check-source.sh
    xcrun swift-format lint --strict --recursive \
        Package.swift Sources Tests Probe/Helper Probe/Fixture Helper Tools Specification
    xcrun swift test --scratch-path {{quote(swift_build)}} -Xswiftc -warnings-as-errors
    xcrun swift test --scratch-path {{quote(swift_build)}} -c release -Xswiftc -warnings-as-errors
    just build release
    bash Tools/test-install-local.sh {{quote(swift_build / "release/ControlKit")}}
    sh Tools/help-check.sh {{quote(cli)}}
    sh Tools/discovery-check.sh {{quote(cli)}}
    sh Tools/skill-check.sh {{quote(cli)}}
    just _fixture
    xcrun xcodebuild build-for-testing -quiet -project Helper/ControlKitRuntime.xcodeproj \
        -scheme ControlKitRuntime -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath {{quote(build_root / "xcode/runtime-helper")}} \
        -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    @printf 'All checks passed for Xcode build %s.\n' {{quote(toolchain)}}

# Install to ~/.local/bin (or <prefix>/bin) and add it to PATH.
install prefix="": (build "release")
    bash Tools/install-local.sh {{quote(swift_build / "release/ControlKit")}} "$1"

# Create a test simulator (newest iOS by default) and print its UDID.
simulator runtime="" device="iPhone-17":
    #!/bin/sh
    set -eu
    prefix=com.apple.CoreSimulator.SimRuntime.
    runtime=${1:-$(xcrun simctl list runtimes available | grep -o "${prefix}iOS-[0-9-]*" | tail -1)}
    [ -n "$runtime" ] || { printf 'No iOS simulator runtime is installed.\n' >&2; exit 1; }
    case "$runtime" in "$prefix"*) ;; *) runtime="$prefix$runtime" ;; esac
    xcrun simctl create "ControlKit $2" "com.apple.CoreSimulator.SimDeviceType.$2" "$runtime"

# End-to-end tests on a dedicated simulator; boots, mutates, shuts down.
acceptance udid: build _fixture
    sh Tools/acceptance.sh {{quote(cli)}} "$1" {{quote(justfile_directory())}}
    sh Tools/session-smoke.sh {{quote(cli)}} "$1"

# Build the fixture app and its probe test runner.
_fixture:
    xcrun xcodebuild build-for-testing -quiet -project Probe/ControlKitProbe.xcodeproj \
        -scheme ControlKitProbe -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath {{quote(build_root / "xcode")}} -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

# Serve the experimental probe helper for 'ControlKit probe request' (max 10 minutes).
[private]
probe-serve udid: build _fixture
    #!/bin/sh
    set -eu
    runtime=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-serve.XXXXXX")
    xcrun swift Tools/ProbeSmoke.swift serve "$1" "$runtime/run"
