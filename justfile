set positional-arguments
set shell := ["sh", "-eu", "-c"]

# Honor DEVELOPER_DIR; never modify xcode-select. Compiler outputs must not cross toolchains.
toolchain := `xcrun xcodebuild -version | awk '/^Build version /{print $3;ok=1}END{exit !ok}'`
build_root := justfile_directory() / ".build/toolchains" / toolchain
export CONTROLKIT_SWIFT_BUILD := build_root / "swift"
export CONTROLKIT_PROBE_CLI := build_root / "swift/debug/ControlKit"
export CONTROLKIT_PROBE_PRODUCTS := build_root / "xcode/Build/Products"
export CONTROLKIT_XCODE_BUILD := build_root / "xcode"
export CONTROLKIT_SOURCE_ROOT := justfile_directory()
# Development runs, tests, and acceptance must not fill a tester's ~/Library/Logs/ControlKit.
export CONTROLKIT_LOG_DIRECTORY := build_root / "logs"

# List development commands. Use `just --show RECIPE` to inspect one before running it.
default:
    @just --list

# Show the selected Xcode, Swift, build directory, and installed runtimes.
doctor:
    xcrun xcodebuild -version
    xcrun swift --version
    @printf 'Build root: %s\n' {{quote(build_root)}}
    xcrun simctl list runtimes

# Build the experimental CLI (debug or release).
build configuration="debug":
    @case "$1" in debug|release) ;; *) printf 'Use debug or release.\n' >&2; exit 2 ;; esac
    xcrun swift build --scratch-path "$CONTROLKIT_SWIFT_BUILD" -c "$1" -Xswiftc -warnings-as-errors >&2

# Run Swift unit and executable-contract tests locally.
test:
    xcrun swift test --scratch-path "$CONTROLKIT_SWIFT_BUILD" -Xswiftc -warnings-as-errors

# Run the same tests under optimized code; invariants must not rely on debug-only behavior.
test-release:
    xcrun swift test --scratch-path "$CONTROLKIT_SWIFT_BUILD" -c release -Xswiftc -warnings-as-errors

# Replay deterministic model scenarios with an unsigned 64-bit decimal seed.
test-seeded seed="42":
    CONTROLKIT_TEST_SEED="$1" xcrun swift test --scratch-path "$CONTROLKIT_SWIFT_BUILD" \
        -Xswiftc -warnings-as-errors --filter SeededSessionTests

# Enforce source limits and production/test package boundaries using the selected Swift compiler.
source-check:
    bash Tools/check-source.sh

# Check formatting without editing files.
format-check:
    xcrun swift-format lint --strict --recursive \
        Package.swift Sources Tests Probe/Helper Probe/Fixture Helper Tools Specification

# Apply the selected Xcode's formatter to owned Swift sources.
format:
    xcrun swift-format format --in-place --recursive \
        Package.swift Sources Tests Probe/Helper Probe/Fixture Helper Tools Specification

# Verify help at every implemented command level without a simulator or token.
help-check: build
    sh Tools/help-check.sh "$CONTROLKIT_PROBE_CLI"

# Verify discovery JSON, exit status, precedence, and the checked-in Xcode project without a simulator.
discovery-check: build
    sh Tools/discovery-check.sh "$CONTROLKIT_PROBE_CLI"

# Verify the installed agent skill's safety rules and referenced top-level command help.
skill-check: build
    sh Tools/skill-check.sh "$CONTROLKIT_PROBE_CLI"

# Build the fixture and independent XCTest helper for the selected toolchain.
probe-build:
    xcrun xcodebuild build-for-testing -quiet -project Probe/ControlKitProbe.xcodeproj \
        -scheme ControlKitProbe -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$CONTROLKIT_XCODE_BUILD" -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

# Compile the independent lifecycle-only production helper without booting a simulator.
helper-build:
    xcrun xcodebuild build-for-testing -quiet -project Helper/ControlKitRuntime.xcodeproj \
        -scheme ControlKitRuntime -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$CONTROLKIT_XCODE_BUILD/runtime-helper" -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

# All non-interactive local checks. Does not boot or erase a simulator.
check: source-check format-check test test-release install-check help-check discovery-check \
        skill-check probe-build helper-build
    @printf 'Local checks passed for %s.\n' {{quote(toolchain)}}

# Run the built CLI; no arguments shows help.
cli *args: build
    @if [ "$#" -eq 0 ]; then set -- --help; fi; "$CONTROLKIT_PROBE_CLI" "$@"

# Inspect read-only repository metadata; incomplete choices exit nonzero with a JSON report.
probe-discover *args: build
    @"$CONTROLKIT_PROBE_CLI" probe discover "$@"

# Verify bounded Apple-tool scheme/configuration validation against the checked-in fixture project.
xcode-check: build
    @"$CONTROLKIT_PROBE_CLI" probe discover --project . --xcode-project Probe/ControlKitProbe.xcodeproj \
        --scheme ControlKitProbe --configuration Debug --validate-xcode

# Exercise authenticated helper startup/cache reuse/retirement on an explicitly booted simulator.
helper-check udid *args: build
    @device=$1; shift; "$CONTROLKIT_PROBE_CLI" probe helper-check --device "$device" \
        --source {{quote(justfile_directory())}} --cache {{quote(build_root / "helper-cache")}} "$@"

# Boot a dedicated simulator, exercise graceful and disconnected helpers, then shut it down.
runtime-smoke udid: build
    sh Tools/runtime-smoke.sh "$CONTROLKIT_PROBE_CLI" "$1" \
        {{quote(justfile_directory())}} {{quote(build_root / "helper-cache")}}

# Exercise production session scheduling, observation, interactions, uncertainty, and recovery.
session-smoke udid: build probe-build
    sh Tools/session-smoke.sh "$CONTROLKIT_PROBE_CLI" "$1"

# Run the complete build/install/launch/session/UI/logs/stop local acceptance workflow.
acceptance udid: build
    sh Tools/acceptance.sh "$CONTROLKIT_PROBE_CLI" "$1" {{quote(justfile_directory())}}

# Run 1–3 bounded complete acceptance rounds. Retains bounded supervisor evidence.
acceptance-soak udid rounds="3": build
    sh Tools/acceptance-soak.sh "$CONTROLKIT_PROBE_CLI" "$1" \
        {{quote(justfile_directory())}} "$2"

# Install to ~/.local/bin by default and persist PATH for SHELL (zsh/bash/fish). No sudo.
install-local prefix="": (build "release")
    bash Tools/install-local.sh "$CONTROLKIT_SWIFT_BUILD/release/ControlKit" "$1"

# Test installation and PATH setup with temporary homes; never edits your shell configuration.
install-check: (build "release")
    bash Tools/test-install-local.sh "$CONTROLKIT_SWIFT_BUILD/release/ControlKit"

# Create a dedicated simulator. Runtime/device arguments are identifier suffixes; prints its UDID.
probe-create runtime="iOS-26-4" device="iPhone-17" name="ControlKit Development":
    xcrun simctl create "$3" "com.apple.CoreSimulator.SimDeviceType.$2" \
        "com.apple.CoreSimulator.SimRuntime.$1"

# Boot an explicitly selected simulator and wait for readiness.
probe-boot udid:
    xcrun simctl boot "$1"
    xcrun simctl bootstatus "$1" -b

# Shut down only the explicitly selected simulator.
probe-shutdown udid:
    xcrun simctl shutdown "$1"

# Run the live smoke/fault checks on a dedicated, booted simulator. Retains private temp logs.
probe-smoke udid: build probe-build
    #!/bin/sh
    set -eu
    runtime=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-smoke.XXXXXX")
    printf 'Private artifacts: %s/run\n' "$runtime"
    xcrun swift Tools/ProbeSmoke.swift "$1" "$runtime/run"

# Bounded sequential soak, NOT concurrent-agent qualification (1–10 rounds, 0–100 extra reads).
probe-stress udid rounds="3" inspections="20": build probe-build
    #!/bin/sh
    set -eu
    case "$2:$3" in *[!0-9:]*|:*|*:) printf 'Counts must be integers.\n' >&2; exit 2 ;; esac
    [ "$2" -ge 1 ] && [ "$2" -le 10 ] && [ "$3" -le 100 ]
    runtime=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-stress.XXXXXX")
    printf 'Private artifacts: %s\n' "$runtime"
    round=1
    while [ "$round" -le "$2" ]; do
        printf '\nRound %s/%s\n' "$round" "$2"
        xcrun swift Tools/ProbeSmoke.swift "$1" "$runtime/run-$round" "$3"
        round=$((round + 1))
    done

# Keep a probe running for manual requests (max 10 minutes). Prints a private connection-file path.
probe-serve udid: build probe-build
    #!/bin/sh
    set -eu
    runtime=$(mktemp -d "${TMPDIR:-/tmp}/controlkit-serve.XXXXXX")
    xcrun swift Tools/ProbeSmoke.swift serve "$1" "$runtime/run"

# Send a manual probe operation; pass the connection.json path printed by probe-serve.
probe-request connection operation *args: build
    @connection=$1; shift; "$CONTROLKIT_PROBE_CLI" probe request "$@" --connection "$connection"
