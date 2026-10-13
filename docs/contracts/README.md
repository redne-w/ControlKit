# Milestone 2 — approved production contract

Status: approved for implementation by redne-w at the milestone-2 review gate. Milestones 3–12 now
implement the simulator-only MVP: foundations, discovery, runtime/helper, supervisor/sessions,
observation/interaction, app lifecycle, setup/run orchestration, and local acceptance.
Experimental `ControlKit probe` commands remain separate adapters without production guarantees.

| Document | Decisions |
| --- | --- |
| [CLI](CLI.md) | Command organization, selectors, output, and side effects |
| [Protocol](PROTOCOL.md) | Identity, framing, authentication, results, and duplicate requests |
| [Lifecycle](LIFECYCLE.md) | Ownership, scheduling, fencing, cancellation, and recovery |
| [Limits](LIMITS.md) | Initial resource and deadline budgets, with rationale |
| [Verification](VERIFICATION.md) | Acceptance cases and executable reference-model boundaries |

## Approved decisions

1. Add **`session recover`**. Recovery is explicit, never replays a command, and requires a new
   inspection before further mutations.
2. Add **`session status --request-id`** to retrieve an accepted request's receipt without repeating
   its action. Store compact receipts for the session lifetime, even after a large result expires.
3. Pin a supervisor to one exact Xcode installation/build at a time. Multiple simulator sessions
   share that toolchain. Reject incompatible clients while jobs/sessions are active.
4. Use a host-owned, loopback-only listener for helper connections. The helper connects outward and
   authenticates with its per-launch token. This avoids reserving a port and releasing it before
   the helper binds. The probe currently connects in the opposite direction; milestone 6 must verify
   this transport change before it becomes a supported guarantee.
5. Separate screenshots from JSON control messages, with bounded binary chunks and explicit artifact
   metadata. Keep the small probe's base64 transport experimental.
6. Local installation and Just workflows are development conveniences, not distribution packaging.

The public XCTest architecture is unchanged. Xcode 27 verification is recorded in
[the compatibility report](../XCODE_27.md). No iOS 27 runtime or production application has been tested.

## Reference specification

`Specification/` contains a **reference model**, linked only into tests, and a result-envelope
validator. It makes safety rules reviewable with concrete event traces; it is not the production
supervisor, dispatcher, or schema implementation.

The model assumes the caller has authenticated and checked supervisor epoch/session identity.
It models a single session's queue, generation, deduplication, terminal receipts, and recovery.
It does not prove process retirement, enforce wall-clock deadlines, simulate Apple internals, or
implement the whole wire protocol. JSON fixture tests cover the envelope, not every operation payload.

Measured production evidence and remaining limitations are in the milestone reports and
[the completed plan](../PLAN.md).
