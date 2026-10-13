# Milestones 7–9 — supervisor, observation, and interaction

Status: implemented together with owner approval and ready for review. Stop before milestone 10.

## Delivered

- An automatically started, finite-idle local supervisor in `ControlKitSupervisor`, pinned to an exact
  developer directory/Xcode build/simulator SDK. Idle supervisors can be replaced when a client
  selects another supported Xcode; live sessions reject the mismatch.
- Owner-only Unix-domain control socket (directory 0700, socket 0600, same-UID peer check), protocol
  version 1 requests, one terminal envelope per CLI invocation, 32-client admission, 64 KiB requests,
  and 2 MiB responses.
- Production `session start/list/status/recover/stop` and `ui
  inspect/screenshot/tap/type/swipe/scroll/wait`, with complete nested help and `--json`.
- A synchronous production session transition core: four live sessions, one owner per simulator,
  eight waiting commands per session/32 globally, one dispatched UI command per simulator, original
  monotonic deadlines, generations, fences, explicit recovery, and retained compact receipts.
- Bounded accessibility snapshots and actionable references using public XCTest snapshots/queries
  only. No debug-description parsing, XPath, predicates supplied by users, or private APIs.
- Separate bounded PNG frames with SHA-256/count validation, private artifact retention, and atomic
  no-clobber export.

App build/install/launch/terminate, production `sim` commands, final setup/run orchestration, logs,
physical devices, and remote access remain out of scope. `session start` requires an already booted
simulator and foreground installed app, verifies both, and never launches or resets either.

## Supervisor and scheduling

The CLI starts the same executable in an internal detached supervisor mode. It retains an exclusive
owner lock and exits after two empty minutes. Every start creates a new supervisor epoch. The
supervisor accepts up to 32 authenticated local clients; the four per-device session workers may run
in parallel, while each session follows admission order with one effect in flight.

State transitions hold one condition lock and never suspend. Helper/process/filesystem effects occur
after a transition returns dispatch ownership. Concurrent callers reserve bounded queue/receipt
storage before waiting. Deadlines are rechecked before dispatch. A queued expiry is `not_dispatched`;
any transport/framework/decode expiry after dispatch is `unknown` and fences even a read, because a
stalled helper may remain busy.

Each session retains up to 10,000 compact receipts. The epoch management registry additionally caps
at 10,000 receipts and 16 MiB reserved bytes. Full results retain at most 16 entries/4 MiB per session;
eviction leaves the compact receipt and returns `result_expired`, never redispatch. Reusing a request
ID with different semantic parameters returns `request_id_conflict`.

Session idle lifetime is 10 minutes and hard lifetime is 30 minutes. Expiry requests cancellation,
waits for effect ownership to return, and releases the device claim only after authenticated runner
retirement. Status polling does not extend either lifetime. Ctrl-C emits a final conservative JSON
envelope and exit 130: `not_dispatched` before send or `unknown` after send.

All simulator mutations and sessions use the same owner-only per-device lease directory. Live evidence
confirmed a simulator shutdown request is rejected while a session owns that device.

## Failure, recovery, and restart

After dispatch, a lost reply never causes replay. The receipt becomes unknown, queued commands become
not-dispatched, snapshots are invalidated, and further UI work is rejected. `session recover`:

1. keeps the device lease and retires the exact authenticated runner/process ownership;
2. increments helper generation and performs a fresh authenticated outward connection;
3. verifies the target app remains foreground without activating it;
4. enters `needsInspection`; only a successful fresh inspection returns to ready.

Old-generation replies and stale references cannot complete new-generation work. Stop preserves the
app process/data and simulator, and is successful only after retirement. A bounded stop may return
unknown while an Apple action is still inside XCTest; repeating stop continues cleanup without
replaying the action.

Exactly-once behavior across supervisor crashes is intentionally not promised. The protected
per-device record survives a crash. A new supervisor refuses that device when ownership/retirement
cannot be proven; it never kills by process name or guesses from a stale PID. Automated cross-epoch
adoption/cleanup is not implemented, so an unclean supervisor crash currently requires operator
inspection of the private runtime record. This is fail-closed behavior, not transparent recovery.

## Observation and references

Inspection snapshots are iterative breadth-first traversals bounded to:

| Resource | Bound |
| --- | --- |
| Emitted nodes | 512 |
| Traversal depth | 32 |
| JSON response | 2 MiB |
| Each identifier/label/value | 4 KiB UTF-8 |
| Retained actionable snapshots | 1 per session |

Results report snapshot UUID, helper generation, app, monotonic capture time, orientation, screen
point dimensions, coordinate space, parent indices, type/identifier/label/value, enabled/selected,
frames, visited/emitted counts, and explicit node/depth/byte/attribute truncation. Secure-text-field
values are always omitted. XCTest creates its internal snapshot before ControlKit traversal; its memory
and latency are not claimed as owned bounds.

References contain no raw XCTest objects. The helper retains a locator and frame for the current
snapshot only, requeries at dispatch, requires one match, and rejects changed/ambiguous/stale targets.
Inspection replaces the prior snapshot; mutations/recovery/stop/expiry invalidate it. Coordinate taps
require the matching snapshot and revalidate app screen frame and orientation before using public
screen-point coordinates. External UI changes remain possible between observation and action.

## Interaction and artifacts

Selectors are exactly one of: exact identifier; exact label with optional inspected numeric element
type; snapshot reference; or finite screen-point x/y plus snapshot. User-supplied predicate code and
"first match" behavior do not exist. Zero and multiple matches are distinct errors. Typing requires a
plain/secure text field and appends literal text; `--text-stdin` keeps text out of argv. Secure values
remain redacted from later snapshots.

`swipe` direction means finger motion. `scroll` direction means content motion and deliberately
reverses the finger gesture. Wait supports exists/absent/hittable, samples no faster than 200 ms,
uses at most 300 samples, and remains under the original deadline.

Screenshots are capped at 32 MiB. The JSON manifest includes artifact UUID/media type/byte count/
SHA-256/pixel dimensions/scale/capture time. Ordered 64 KiB-or-smaller binary frames are not
multiplexed. The host validates exact count and digest before publication. Supervisor-owned screenshot
storage is capped at 256 MiB. Exports use a same-directory temporary regular file, fsync, and exclusive
atomic rename; existing outputs are rejected before dispatch and again at publication.

## Verification performed

Machine: macOS 26.7, Apple silicon, dedicated iOS 26.4.1 simulator
`96E15F23-38CB-4291-9A8D-649EF6861ACA`.

Live `just session-smoke` passed on:

- Xcode 27.0 (`27A266a`, simulator SDK build `24A430`);
- Xcode 26.4.1 (`17E202`, simulator SDK build `23E252`).

Each workflow built/installed/launched the fixture explicitly, then verified automatic supervisor
startup, attach without relaunch, snapshot, exact selectors, tap, Unicode type, keyboard dismissal,
content scroll, wait, screenshot transfer/export, duplicate mutation ID without redispatch, forced
post-action disconnect, `outcome_unknown`, fence, runner replacement, generation increase,
inspection-required blocking, fresh inspection, resumed mutation, stop, unchanged app PID/data, and
simulator shutdown after lease release. The fixture includes a populated secure text field; its fixed
test value was absent from snapshot JSON.

Additional live checks measured:

- 12 simultaneous inspections: 9 admitted/completed, 3 explicit `busy`, no hidden overflow.
- Reference action followed by stale-reference rejection while the session remained ready.
- Snapshot-grounded coordinate tap and content-direction scroll.
- Simulator shutdown rejected with `device_busy` until session retirement.
- Idle exact-toolchain replacement 27 → 26.4.1 → 27 with a new epoch each time.

Unit/local checks include fragmented/duplicate/deep/invalid frames, binary digest/count failure,
selector-family validation, result-envelope null fields, owner-only local sockets, atomic no-clobber
artifacts, queue/receipt boundaries, stale generations, uncertainty/recovery/stop rules, and
deterministic generated transition sequences (64 scenarios × 100 events for each recorded seed).
`just check` passed under both supported Xcodes with 90 test functions in each debug/release run,
plus parameterized cases, 1,280 reference-model scenarios, and the generated production sequences.
An isolated-prefix install selected its installed `<prefix>/share/ControlKit` helper inputs without
`CONTROLKIT_SOURCE_ROOT`; development Just commands continue to inject the checkout explicitly.

## Limits of evidence

- No iOS 27 runtime, physical device, production app, four-simulator load, long soak, or external human
  interference qualification was performed.
- Public XCTest action APIs can record framework issues rather than throw. A public
  `XCTestObservation` observer turns newly recorded mutation issues into uncertain outcomes, but this
  cannot prove Apple did not submit a partial gesture or text sequence.
- Snapshot and screenshot captures are separately timestamped, not atomic.
- Same-UID malicious processes remain outside the security boundary.
- Runtime/cache evidence is retained and bounded; there is no automatic eviction while pinning cannot
  be proven. Old development evidence may require explicit operator cleanup.

Proceed to milestone 10 only after review.
