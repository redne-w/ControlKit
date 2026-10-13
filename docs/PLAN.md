# ControlKit design and milestones

## Product

ControlKit is a Swift CLI for backend engineers and agents to prepare and operate iOS simulator apps.
Safety, performance, and developer experience are prioritized in that order, following TigerStyle.

The production architecture is:

```text
CLI → automatically managed local supervisor → independent XCTest helper → app
                         |
                         └→ xcrun / simctl / xcodebuild
```

The CLI and supervisor communicate over an owner-restricted local channel. Helper transport is local
and authenticated. The supervisor, not individual CLI invocations, owns helper lifetimes and
per-simulator command scheduling. State transitions do not suspend; asynchronous effects return
validated events.

Use public XCTest APIs. Never change global Xcode selection. The probe is verified on Xcode 26.4.1
and 27.0 with the iOS 26.4.1 runtime; iOS 27 is not yet tested. Cache helper builds by the exact
toolchain and relevant inputs; do not infer compatibility from version numbers alone.

## Planned command groups

| Group | Responsibility |
| --- | --- |
| `help`, `help <command>`, `--help` | Arguments, defaults, examples, outputs, and side effects |
| `doctor`, `setup` | Diagnosis and guided/noninteractive environment configuration |
| `sim list/create/boot/shutdown` | Simulator lifecycle |
| `app build/install/launch/terminate` | App and artifact lifecycle |
| `session start/list/status/recover/stop` | Automation lifecycle, explicit recovery, and ownership |
| `ui inspect/find/screenshot/tap/type/set-text/swipe/scroll/wait/system-alert` | UI automation |
| `logs` | Bounded diagnostics |
| `run` | Compose preparation, app launch, and session startup |

Default repository discovery uses only canonical `buildServer.json`. Reuse recognized Xcode metadata,
resolve missing build settings with Apple tooling, and ask about ambiguities instead of guessing.
Do not execute arbitrary build-server `argv`. Guide setup when configuration is absent, and store
only additional ControlKit settings. Explicit overrides win. Noninteractive operation never prompts.

## Invariants to specify before production implementation

- One controlling session per simulator; observation and mutation are serialized.
- Every queue, frame, traversal, retry, process, cache, and artifact lifetime has a bound.
- Backpressure is explicit. No invisible, unbounded command backlog.
- Distinguish queued, dispatched, completed, failed, and unknown-outcome commands.
- A timeout after dispatch does not prove cancellation. Never automatically replay a mutation.
- Reject stale responses from old helper generations and stale snapshot references.
- Do not dispatch conflicting work while an abandoned command may still execute.
- Stopping a session does not terminate the app, reset its data, or shut down the simulator.
- Invalid input and operating failures are typed errors. Broken internal invariants fail loudly.
- JSON output and protocol versions are explicit. Diagnostics do not contaminate JSON stdout.
- XCTest's internal resource use and a human's external simulator interactions are not under
  ControlKit's exclusive control.

## Milestones and review gates

Stop after each milestone. Discuss changed assumptions before proceeding.

Milestone 1 is complete. [Xcode 27 verification](XCODE_27.md) also passed.
Milestone 2 and all its [contract decisions](contracts/README.md) are approved.
Milestones 1–9 are approved; their reports remain linked from the README.
**Milestones 10–12 and the simulator-only MVP are ready for final review**: see the
[app/orchestration/acceptance report](MILESTONES_10_12.md).

| # | Milestone | Gate |
| --- | --- | --- |
| 1 | XCTest feasibility | Public APIs, persistent commands, state preservation, latency, fault evidence |
| 2 | Contracts and invariants | Command schemas, state machines, ownership, failure rules, resource budgets |
| 3 | Production Swift foundation | Package boundaries, strict local checks, deterministic test infrastructure |
| 4 | Repository discovery | `buildServer.json`, provenance, overrides, stale/ambiguous configuration |
| 5 | Process and simulator operations | Bounded output, deadlines, ownership, cancellation, lifecycle tests |
| 6 | Helper lifecycle and transport | Toolchain cache, authenticated connection, readiness/version handshake |
| 7 | Supervisor and sessions | Bounded scheduling, generations, per-device ownership, failure injection |
| 8 | Observation | Bounded traversal, references, coordinate metadata, screenshots |
| 9 | Interaction | Targeting, text, gestures, waits, uncertain-outcome handling |
| 10 | App lifecycle | Repository builds or existing artifacts, product selection, install/launch |
| 11 | Setup and orchestration | `doctor`, interactive/noninteractive `setup`, and `run` |
| 12 | Local acceptance | Compatibility, burst/soak, recovery, help, docs, and agent skill |
| Later | Artifact retrieval | Optional existing internal build-artifact integration |

The milestone-1 package and wire format are scaffolding for the experiment, not completion of
milestones 2–9. Do not silently promote the probe into production infrastructure.

There is **no CI work**. All checks are reproducible locally. Distribution and release packaging
are deferred until the owner selects a distribution model. Physical devices, remote access,
arbitrary scripting, a general BSP client, and BFF/Proxyman orchestration are outside initial scope.
