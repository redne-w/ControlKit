# Milestones 10–12 — app lifecycle, orchestration, and final local acceptance

Status: implemented together with owner approval and ready for final review.

## Delivered

- Production `sim list/create/boot/shutdown`, all requiring explicit identities for mutation.
- Production `app build/install/launch/terminate`, with bounded process execution, simulator-platform
  and host-architecture validation, shared device leases, postcondition checks, and no data reset.
- `doctor`, non-writing setup plans, interactive/noninteractive confirmed `controlkit.json` writes,
  bounded redacted `logs`, and compound `run`.
- Complete nested help, reproducible `just acceptance` and three-round `acceptance-soak`.
- `plugins/ios/skills/ios-use-controlkit/SKILL.md`, installed with local helper inputs.

Physical devices, remote access, CI, distribution packaging/signing, arbitrary scripts, and BFF/proxy
orchestration remain out of scope.

## App builds and artifacts

Build resolution preserves the approved precedence:

**explicit options → selected ControlKit profile → canonical `buildServer.json` → unambiguous discovery**.

Before a build, bounded Apple commands validate the scheme, selected configuration in every
participating project, repository confinement, and generic iOS Simulator destination. Package
auto-resolution is disabled; checked-in resolved package versions are required when dependencies
exist. The actual build may execute repository build phases and scripts, so the CLI/help identifies
that trust boundary instead of calling it read-only.

`run` validates/builds against its explicit simulator UDID, so an installed older compatible runtime
can be used even when no runtime matching the Xcode SDK is installed. Standalone `app build` accepts
optional `--device`; without it, the bounded generic simulator destination remains the default.

One original monotonic deadline covers filesystem discovery, all Xcode metadata queries, build,
boot, install, launch, and session startup. Xcode list/build-settings phases may use up to 300 seconds
each, but never beyond the command's remaining `--timeout`; the project build phase is capped at
1,800 seconds. No phase resets or extends the caller's deadline. Xcode choice parsing admits at most
512 schemes and 64 configurations; the first measured large repository reported 279 schemes.

Builds use one global exclusive build lock and owned derived data keyed by sorted exact toolchain
identity plus repository/container/scheme/configuration. The build still runs on every request, so
source changes cannot return a stale artifact. At most four derived-data configurations and 4 GiB/
16,384 entries/depth 32 were initially admitted. Real-repository evidence required a measured
adjustment: one failed Xcode 27 graph alone produced 204,303 entries/17.8 GiB. The final app cache
therefore remains bounded to four configurations, 64 GiB total, 1,048,576 entries, and depth 32.
Scans share the original command deadline. There is no unsafe automatic eviction while a returned
artifact may still be used by another command. Helper/session caches retain their smaller limits.

`-showBuildSettings -json` supplies candidates. ControlKit accepts executable `.app` products for
`iphonesimulator`, rejects zero/multiple matches, and supports explicit target/product/bundle choice.
The selected path must remain under owned derived data. Existing apps are checked without recursive
traversal: non-symlink `.app`, bounded regular `Info.plist`, `DTPlatformName=iphonesimulator`,
`CFBundleSupportedPlatforms` containing `iPhoneSimulator`, bounded bundle/executable names,
non-symlink regular executable, and host architecture (`arm64` on the measured machine).

Install confirms the resulting bundle through `simctl get_app_container`. Launch returns the PID and
activates an already running app without reset. Terminate is idempotent: a normally exited `simctl`
command leaves the explicit desired state even when the app was already absent. Timeout/cancellation
still retains the lease as `outcome_unknown`.

## Doctor and setup

`doctor` reports exact developer directory, Xcode build, simulator SDK, bounded available devices,
first-launch/license status, repository discovery findings, provenance, missing choices, and whether
the exact toolchain passed ControlKit acceptance. It does not accept licenses, download runtimes, or write
configuration.

`setup` prefers canonical `buildServer.json` and tells users to run `xcode-build-server config` when
it is absent. Without `--write`, it only returns a plan. Interactive writes prompt for missing
container/scheme/configuration and confirmation. `--json` implies noninteractive behavior;
`--non-interactive --write` requires `--yes` and complete explicit choices.

Writes contain only explicit `workspace`, `xcodeProject`, `scheme`, and `configuration` fields under
schema version 1. Secrets and machine-local device state have no schema. Files are capped at 64 KiB,
written to a same-directory no-follow temporary regular file, fsynced, and atomically published.
Existing `controlkit.json` is preserved unless `--replace-existing` is explicit.

## Run and diagnostics

`run` requires an explicit simulator. It composes:

1. build one validated app, or validate `--app-path`;
2. boot/wait idempotently;
3. install and confirm;
4. launch/activate;
5. start the authenticated automation session.

The operation uses the epoch management receipt registry, so repeating the same request UUID never
repeats a completed step. A failure returns the ordered completed-step list rather than pretending the
workflow was atomic. It does not erase data or silently shut down the simulator on failure.

Per-session diagnostics retain at most 1,024 fixed-schema events (well below the 16 MiB diagnostic
budget): session transitions, dispatch, known finish, and unknown outcome. Events contain monotonic
time, fixed code, and optional request UUID—never tokens, typed text, selectors, app values, or
subprocess output. `logs` is a finite snapshot; no unbounded follow mode exists.

## Local installation and skill

`install-local` now installs:

- `<prefix>/bin/ControlKit`;
- `<prefix>/share/ControlKit/Helper` and shared wire sources used for exact helper builds;
- `<prefix>/share/ControlKit/skills/ios-use-controlkit/SKILL.md`.

Every destination rejects symlinks before update. An isolated-prefix verification confirmed an
installed binary can start its supervisor using installed helper inputs without
`CONTROLKIT_SOURCE_ROOT`. Development Just recipes inject the checkout explicitly.

The skill teaches agents to diagnose/setup, use one session/generation, inspect before improvising,
select exactly, use stdin for text, preserve request IDs, never replay unknown actions, recover and
inspect, collect bounded logs/screenshots, and stop cleanly.

## Measured evidence

Machine: macOS 26.7, Apple silicon, dedicated iOS 26.4.1 simulator
`96E15F23-38CB-4291-9A8D-649EF6861ACA`.

Complete production acceptance passed on:

- Xcode 27.0 (`27A266a`, simulator SDK `24A430`);
- Xcode 26.4.1 (`17E202`, simulator SDK `23E252`).

The workflow exercised doctor, noninteractive setup in a temporary repository, repository build,
artifact selection/validation, boot, install confirmation, launch, session attach, bounded inspect,
secure-field redaction, tap, PNG export, redacted logs, session stop, app terminate, and simulator
shutdown. A full three-round Xcode 27 soak passed sequentially. Separate milestones 7–9 evidence also
covers burst admission, duplicate mutations, forced disconnect/recovery, references, coordinates,
waits, and exact-toolchain supervisor replacement.

Both exact Xcodes pass the complete non-mutating `just check`: strict source/package boundaries,
format, 92 warnings-as-errors test functions in both debug/release (plus parameterized/generated
scenarios), installation fixtures, every help level, discovery workflow, and both XCTest project
builds. Xcode 26.4.1 continues to emit its known
`DVTDeviceOperation` empty-build-number diagnostic while succeeding.

## Remaining limitations

- No iOS 27 runtime, physical device, production app, multi-simulator four-session load, or long-duration
  real-app soak was measured.
- An unclean supervisor crash remains fail-closed when protected ownership cannot be proven; automatic
  cross-epoch adoption is not claimed.
- Build/helper/runtime caches intentionally fail at bounds rather than evict potentially live evidence.
  Operator-reviewed cleanup is still required.
- Local install is development distribution only. There is no package manager, signing, notarization,
  update mechanism, or CI/release pipeline.
- Existing internal artifact retrieval and BFF/proxy orchestration remain possible later integrations,
  not hidden dependencies of the simulator-only MVP.
