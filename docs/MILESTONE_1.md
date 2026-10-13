# Milestone 1: independent XCTest feasibility

Status: complete; milestone 2 authorized. This report retains the original Xcode 26.4.1 measurements.
Follow-up Xcode 27 verification is recorded [separately](XCODE_27.md).

## Questions answered

| Question | Observed result |
| --- | --- |
| Can the helper be independent of the app? | Yes. UI-test target has no target-app dependency; `XCUIApplication(bundleIdentifier:)` attaches to the separately installed fixture. |
| Can public APIs expose the tree? | Yes. `XCUIElement.snapshot()` returns a public `XCUIElementSnapshot`; iterative traversal produces structured attributes. |
| Can separate CLI processes reuse one runner? | Yes. Each request opens a short-lived connection; the XCTest function remains alive. |
| Can it operate the UI? | Navigation, exact-ID taps, Unicode text entry, scrolling, and screenshots passed. |
| Is app state preserved? | Navigation, a screen-local UUID, and a counter survived normal and forced helper restarts without app activation/relaunch during recovery. |
| Are locator failures recoverable? | Missing and ambiguous IDs returned typed errors; subsequent commands succeeded. |
| Does a client deadline cancel a tap? | No. A deliberately timed-out tap still incremented the counter in the observed run. No retry occurred. |

## Exact local configuration

- Xcode 26.4.1, build 17E202, selected through `DEVELOPER_DIR`.
- iOS 26.4.1, build 23E254a, iPhone 17 simulator.
- macOS 26.7, build 25G229; Apple silicon.
- Debug CLI/helper, controlled UIKit fixture.
- Screen coordinates: 402 × 874 points; captured PNG: 1206 × 2622 pixels, scale 3.

The machine's default Xcode was 26.3 and was not changed. Xcode 27 was not installed during this
initial experiment; the follow-up report covers the subsequently installed toolchain.

## Measurements

These are observations from local smoke runs, not percentiles or service guarantees.
Wall time includes a fresh CLI process and the harness's approximately 20 ms polling granularity.

| Operation | Observed wall time |
| --- | --- |
| First helper startup on a fresh simulator | Approximately 8.6 seconds |
| Subsequent helper startups | Approximately 2.5–3.0 seconds |
| Inspection | Approximately 49–130 ms |
| Screenshot | Approximately 96–122 ms |
| Ordinary counter tap | Approximately 386–416 ms |
| Navigation tap | Approximately 1.25–1.31 seconds |
| Unicode typing | Approximately 1.19–1.78 seconds |
| Upward swipe | Approximately 1.02–2.54 seconds |

Observed snapshots contained 48–119 elements, including the keyboard when present.
Snapshot creation occurs inside XCTest; our 256-node/32-depth limits bound only the subsequent
traversal, not Apple's internal allocation or snapshot work.

## Consequences for the design

1. **Keep the proposed architecture.** The core public-API approach is viable on this configuration.
2. **Keep the helper persistent.** Starting XCTest for every action would dominate latency.
3. **Treat unknown outcomes as a first-class state.** The timeout experiment demonstrated a real
   applied mutation after the CLI had already timed out.
4. **Do not equate XCTest failures with Swift throws.** UI operations can record XCTest issues.
   The probe uses the public `record(_:)` hook to capture issues at the command boundary; production
   classification and failure-isolation rules still need specification and testing.
5. **Public observation is promising, not universally benchmarked.** Larger trees, SwiftUI
   composition, web content, and continuous animations require additional real-app coverage.

## Deliberate probe limitations

- Direct CLI-to-helper loopback transport; no production supervisor, session lease, queue, or
  generation tracking yet. One connection at a time; competing connections are closed.
- One experimental request/response format, not the final CLI contract.
- Lifetime capped at 600 seconds and 200 accepted commands. Framework calls may block the main
  actor; a separate XCTest execution timeout is the outer guard, not per-command cancellation.
- Per-connection framing is bounded; incomplete reads have a ten-second deadline.
- Screenshot bytes cross the probe connection as base64 JSON. The production artifact transport
  remains a milestone-2 design decision.
- Snapshot indices are output metadata, not actionable stable element references.
- Typing covers ordinary text fields, not secure fields, replacement, or keyboard edge cases.
- Swipe is finger-up in a named container, not a full semantic scrolling API.
- Orientation is the raw public XCTest value and may be `unknown`; the probe does not change it
  simply to populate metadata.
- No production app build was provided in this repository. The bundled fixture is not evidence that
  every production screen, login flow, network condition, or animation already works.
- No physical-device, multi-simulator, long-duration, or hostile-client qualification.
- Xcode 27 was outside this initial run; see the follow-up for the exact tested combination.

## Reproduction and acceptance

See the root README for local checks and the live harness. Tests cover frame boundaries, malformed
requests, token/text/identifier validation, endpoint limits, JSON round trips, and command help.
Fourteen Swift test functions (including parameterized boundary cases), local style checks, debug
and release builds, and help-contract checks passed. Three live smoke runs passed, with the final
run also verifying PNG dimensions/scale, refusal to overwrite screenshots, and successful forced
helper termination. The live harness checks app state rather than treating command success as
sufficient.

Before production implementation, milestone 2 must formalize protocol/session states and budgets,
including how to fence a runner after an abandoned mutation. No architectural change is required
by the observations so far.
