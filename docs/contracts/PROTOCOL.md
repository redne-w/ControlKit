# Local protocol and output contract

This is a production proposal. The milestone-1 probe wire format is not this protocol.

## Boundaries and trust

- CLI ↔ supervisor: Unix-domain socket in an owner-only, non-repository runtime directory;
  socket permissions and peer-user identity must be checked.
- Supervisor ↔ helper: loopback TCP only. Supervisor binds first; each launched helper connects
  outward with a fresh per-launch token. Authenticate before command admission.
- Do not expose HTTP, WebDriver, remote bind addresses, or arbitrary code evaluation.
- Same-UID processes are not strongly isolated from each other. Leases prevent accidental conflicts;
  do not market a session ID as a security boundary against a malicious process owned by the user.
- Never put tokens into arguments, repository files, normal logs, JSON results, or shared artifacts.
  If launch tooling requires a file, keep it in the private runtime directory with mode 0600.
- Runtime paths must resist symlink substitution; validate file type, owner, size, and permissions
  using the opened descriptor. Protect startup with an exclusive ownership lock, not PID alone.

The supervisor pins an exact developer-directory/toolchain identity for its lifetime. Reject a
different toolchain while sessions/jobs are active. An idle supervisor may be replaced safely before
new work. CoreSimulator itself can refresh its shared service when Xcode versions change, so do not
promise simultaneous mixed-Xcode sessions.

Milestone 6 implements this direction and authentication for lifecycle-only helper verification.
Milestones 7–9 add the owner-only Unix socket supervisor, bounded client/session registries, UI
operations, screenshot chunks, and public result envelope. Milestones 10–12 add simulator/app jobs
and orchestration to the same epoch receipt registry. Experimental `probe` commands still do not
inherit production guarantees.

## Handshake and identity

Protocol major 1 requires an explicit handshake before requests. No "best effort" version fallback.
Negotiate capabilities such as inspection and screenshot transfer; unsupported operations fail
before dispatch. Additional optional response fields are additive; unrecognized request fields or
operation names are rejected.

Every request carries:

```json
{
  "protocolVersion": 1,
  "supervisorEpoch": "<uuid>",
  "requestId": "<uuid>",
  "operation": "ui.tap",
  "sessionId": "<uuid>",
  "helperGeneration": 1,
  "remainingMilliseconds": 30000,
  "parameters": { "identifier": "recovery.details" }
}
```

The epoch changes on every supervisor start. Session IDs are never reused. Generation increases
when a runner is replaced. A reply must match epoch, session, generation, and request identity.
Authentication and these identity checks precede any state transition.

Sessionless management commands omit session/generation but still carry the connected epoch.
The CLI obtains that epoch before its first effectful request, and never reconnects/replays an
uncertain request under a new epoch. Old-epoch requests fail closed. Exactly-once behavior across
supervisor crashes is **not** promised.

## Framing and artifacts

Use a four-byte unsigned big-endian frame length, then a one-byte frame kind and its payload.
Length includes the kind byte. Validate length and phase-specific limits before allocating/decoding.
Reject zero, oversized, truncated, unknown-kind, and out-of-order frames.

Kinds: JSON control and binary artifact chunk. A screenshot's JSON manifest declares artifact ID,
media type, byte count, pixel dimensions, scale, and SHA-256. It is followed by ordered chunks for
that request; validate the cumulative count and final digest before publishing.
Never multiplex chunks from multiple operations on a helper connection. PNG bytes are not base64
fields in the production control response. A transfer failure cannot expose a partial artifact as
a successful screenshot.

Limits, including unauthenticated input and slow/incomplete-frame deadlines, are in [LIMITS.md].
The supervisor is the authority on monotonic deadlines. Forward remaining time, not wall-clock
timestamps assumed to be synchronized with the helper.

## Public result envelope

With `--json`, a result has this common structure:

```json
{
  "schemaVersion": 1,
  "requestId": "<uuid>",
  "supervisorEpoch": "<uuid or null before connection>",
  "sessionId": "<uuid or null>",
  "helperGeneration": 1,
  "ok": false,
  "completion": "unknown",
  "error": {
    "code": "outcome_unknown",
    "message": "The helper disconnected after dispatch. Do not replay this action."
  },
  "data": null
}
```

The strings in angle brackets illustrate types, not literal valid UUIDs; executable JSON examples
are in `Tests/ControlKitContractTests/Fixtures`.

Rules:

- `ok == true` iff `error == null`; success requires `completion == "finished"`.
- `not_dispatched`: rejected/cancelled/expired before dispatch, with no operation sent downstream.
- `finished`: the handler reached a known terminal result. This alone is not a rollback guarantee;
  multi-step app/build workflows can have completed earlier steps before a later known failure.
- `unknown`: completion is uncertain after dispatch; use `outcome_unknown` and fence the affected
  session. Interrupted mutations and errors after a possibly partial UI action use this state.
- A helper may report a known locator/precondition failure as `finished` without fencing only if
  no action began. Never translate every XCTest issue into a harmless locator failure.
- Generation, when present, is positive and requires session and epoch identity.
- `data` is an operation-specific object on success, otherwise null. Compound-workflow failure
  diagnostics reference completed-step receipts rather than pretending the workflow was atomic.
- Emit exactly one terminal envelope per CLI invocation. Progress belongs on stderr.
- Help and pre-connection failures require no supervisor; nullable identities are intentional.

Initial payloads: device inventory; environment findings with provenance; build artifact descriptor;
session state and limits; bounded request receipt; snapshot and truncation metadata; screenshot
manifest/export path; action acknowledgement; or wait condition result. Each command must add golden
payload examples and validation tests when its implementation milestone begins.

## Duplicate requests and receipts

Within an epoch/session, retain a compact receipt for every accepted request until session retirement.
Compare a canonical fingerprint of operation and semantic parameters. Identity, authentication,
and transport timing do not change the requested action; altered action parameters with the same ID
are a `request_id_conflict`.

A duplicate returns existing queued/dispatched/terminal status. It is **never dispatched again**.
An expired large result returns `result_expired` with its compact completion receipt, not reexecution.
Unknown receipts remain unknown even if a late response is logged as additional evidence; they do not
silently unblock the caller or undo a result already returned.

Do not evict duplicate-detection receipts while still admitting work into the same session.
At the receipt budget, reject new work and require explicit session renewal. Old session/epoch
identities cannot become fresh requests after cleanup or restart.

Sessionless accepted jobs obey the same rule in a bounded epoch-scoped registry; when full, reject
new jobs rather than evicting identities and risking reexecution. The registry can reset only with
an explicit new epoch after all jobs are terminal.
