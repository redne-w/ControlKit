# Milestone 3 — Swift foundation

Status: implemented and verified; awaiting review before repository discovery.
The approved XCTest/supervisor architecture and production command contract have not changed.

## Package boundaries

| Target | Ownership and permitted dependencies |
| --- | --- |
| `ControlKit` | Thin executable root; Argument Parser and experimental probe command registration |
| `ControlKitProbeCLI` | Existing `probe request` adapter; Argument Parser and `ControlKitProbeCore` |
| `ControlKitProbeCore` | Existing experimental client/wire types; not the production protocol |
| `ControlKitCore` | Production value types; Swift standard library only, no target dependencies |
| `ControlKitContractSpecification` | Milestone-2 reference model; no target dependencies; tests only |
| `ControlKitTestSupport` | Deterministic test utilities; depends only on `ControlKitCore`; tests only |

The only product remains the `ControlKit` executable. New core and test utilities use `package` access,
not a promised public SDK. Swift 6 language mode makes strict concurrency checking explicit.
The Xcode-built experimental helper and UIKit fixture retain their existing independent targets.

Do not create empty discovery/process/supervisor modules in anticipation of future work. Add each
boundary when its milestone has concrete ownership to enforce. The executable does not yet use
the production core: it has no production commands. No probe code was promoted into that core.

## Production primitives

- `MonotonicInstant`: unsigned milliseconds relative to one clock owner's fixed origin.
- `Deadline`: checked addition, positive duration, exact expiry boundary, saturating remaining time.
  It is immutable so queueing cannot silently refresh a deadline.
- `HelperGeneration`: positive, checked successor; exhaustion cannot wrap and reuse an identity.

These values do not read wall time, spawn work, retry, or cancel anything. An actual clock adapter,
operation-specific timeout caps, clock-domain ownership, and dispatch/cancellation semantics belong
to the process/session milestones. In particular, expiry is not proof of cancellation. Generation
checks never replace epoch/session validation.

The reference model remains independent rather than becoming the production scheduler by accident.
Tests exercise its accepted safety rules alongside the production time/generation primitives.

## Deterministic test infrastructure

- Value-owned manual clock; no real sleeps or global mutable clock state.
- Fixed SplitMix64 algorithm with known-vector tests. Wrapping arithmetic is intentional here,
  never for production identity/deadline arithmetic.
- Explicit modulo sampling for test choices; no dependency on stdlib random sampling behavior.
- Bounded diagnostic suffix: 32 entries, at most 256 input UTF-8 bytes each.
- Default seeds: `0`, `1`, `42`, `3735928559`, and `18446744073709551615`.
- 256 bounded scenarios per seed: queue capacities 1–8 and four lifecycle outcomes. Scenarios cover
  ordering, duplicates, queue rejection, pre/post-dispatch expiry, partial failure, stale responses,
  recovery, fresh inspection, and stop. This is generated scenario coverage, not exhaustive fuzzing.

Failures carry a seed and scenario trace. A seed is also printed before its scenarios, including
when an internal invariant stops the test process. Replay with:

```sh
just test-seeded 42
```

`CONTROLKIT_TEST_SEED` optionally selects one unsigned decimal 64-bit seed; invalid values fail rather
than falling back to randomness. There is no automatic retry of failing tests. The same generator,
manual-clock, and trace helpers are available to future production transition tests.

## Strict local verification

`just check` now includes:

1. Compiler-backed source limits and package-boundary audit.
2. Strict formatting, debug tests, and optimized release tests.
3. CLI build/help checks and Xcode fixture/helper compilation, with compiler warnings as errors.

`just source-check` uses Swift/Foundation and the system Bash, with no new third-party dependency.
It reads at most 1 MiB per source/manifest and 8 MiB per compiler dump, checks at most 256 source
files and 64 package targets, and limits each parser's CPU allowance to 30 seconds.
It covers explicit functions, initializers, deinitializers, and accessors. Closures and semantic
safety rules still need review. Source lines count Swift characters, not terminal display cells.

The audit rejects a production target reaching test support or the reference model, including
transitive dependencies, and requires dependency-free core/specification targets.
The compiler's parse dump is **development tooling**, not a stable production interface. Synthetic
boundary fixtures and a real oversized-function fixture exercise the checker on the selected
compiler; unrecognized declaration ranges fail closed. Xcode updates require rerunning these checks.
External build-tool wall-clock execution is not bounded by this script; it is not the production
subprocess runner planned for milestone 5.

## Evidence collected

- `just check` passed under Xcode **26.4.1 (17E202)** and **27.0 (27A266a)**.
- **36 Swift test functions** passed in debug and release on each toolchain, including parameterized
  boundary cases and 1,280 seeded model scenarios per default run.
- Explicit replay of seed `18446744073709551615` passed. Empty, negative, nonnumeric, and
  overflowing seed values were rejected instead of silently selecting another sequence.
- Checker self-tests and the real 71-line compiler fixture passed on both toolchains.
- The relocated probe passed its full live smoke/fault harness under Xcode 27 with the
  **iOS 26.4.1** iPhone 17 simulator: navigation, Unicode input, scrolling, screenshots, errors,
  state-preserving restart, uncertain mutation, and forced helper recovery.
- Workspace-local release installation and installed-command help passed.

The timed-out tap again applied, reinforcing the existing uncertainty contract. No iOS 27 runtime,
production app, concurrent supervisor, or production teardown guarantee was tested. The dedicated
simulator was shut down after verification; global Xcode selection was not changed.

## Gate and deferred work

No repository configuration discovery, production JSON decoder, process runtime, listener,
supervisor, session queue, simulator lifecycle, or production UI commands were implemented.
No CI, distribution, or additional implementation dependencies were added.

Milestone 4 will implement canonical `buildServer.json` discovery, provenance, overrides, and
stale/ambiguous configuration handling. Stop here for review before that work.
