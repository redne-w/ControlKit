# Xcode 27 compatibility follow-up

## Outcome

The unchanged public-XCTest probe built and passed its live checks under **Xcode 27.0 (27A266a)**.
No XCTest API or Xcode-project changes were required. This supports continuing with the chosen
architecture; it is not certification of every Xcode/runtime combination.

Exact configuration:

- `/Applications/Xcode-27.0.0.app/Contents/Developer`, selected with `DEVELOPER_DIR`.
- Swift 6.4; macOS 26.7 on Apple silicon.
- iPhone 17 simulator, **iOS 26.4.1 (23E254a)**.
- Dedicated device `96E15F23-38CB-4291-9A8D-649EF6861ACA`, controlled UIKit fixture.
- The global Xcode selection remained unchanged.

There is **no iOS 27 runtime installed** on this machine. Production application screens, physical
devices, concurrent sessions, and simultaneous mixed-Xcode use were not tested.

## Observed behavior

The baseline run verified public snapshots, separate CLI invocations sharing a persistent runner,
exact-ID taps, Unicode input, scrolling, PNG geometry/scale, structured missing/ambiguous-element
errors, refusal to overwrite screenshots, and app state surviving normal and forced helper restarts.

The deliberately timed-out tap still applied. Timeout remains an uncertain outcome, not cancellation;
the harness recovered without replaying the action.

| Operation | Baseline observed wall time |
| --- | --- |
| First helper startup in this run | 6.07 seconds |
| Subsequent helper startups | 2.03–2.04 seconds |
| Inspection | 45–98 ms |
| Screenshot | 106 ms |
| Counter tap | 392–399 ms |
| Navigation tap | 1.30 seconds |
| Unicode typing | 1.62 seconds |
| Upward swipe | 1.03–2.53 seconds |

These are local observations, not percentile estimates or performance guarantees. CLI process
startup and the harness's roughly 20 ms polling granularity are included.

## Development workflow verification

After adding Just and the private connection-file flow:

- Two sequential smoke/fault rounds passed, with 20 additional inspections each.
- Manual `probe-serve` plus separate `probe-request` calls passed: ping, inspection, navigation,
  counter mutation, screenshot, and orderly stop.
- Connection files were mode 0600; permission, symlink, size, and decoding checks have unit tests.
- The CLI dependency build writes diagnostics to stderr, preserving JSON-only stdout in
  `just probe-request`.
- `just check` passed on Xcode 27.0 and 26.4.1: 27 Swift test functions (including parameterized
  boundary cases), formatting, debug/release builds, help checks, and fixture/helper builds.
- Local installation into `.build/local/bin/ControlKit` and the installed binary's help passed.

The minimal Debug project now explicitly disables copy-phase stripping. A clean 26.4.1 build
otherwise attempted to strip Apple's already-signed XCTest frameworks and warned; retaining their
symbols removes that unnecessary operation without suppressing compiler warnings.

The sequential soak is not concurrent-agent stress qualification. Production failure injection and
late-input isolation remain explicit acceptance gates in the milestone-2 contract.

## Reproduce

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
just check
just probe-create
just probe-boot <returned-udid>
just probe-smoke <returned-udid>
just probe-stress <returned-udid> 2 20
just probe-shutdown <returned-udid>
```

The recipes retain credential-free measurements in `summary.json` inside the printed private
temporary directory. Neighboring configuration and raw logs can contain credentials; do not share
the entire directory. Build products are isolated under `.build/toolchains/27A266a/`.
