# Contract verification and implementation acceptance

`just test` executes the milestone-2 reference model and result-envelope examples.
`just check` also checks style, debug/release builds, help, and fixture/helper compilation.
No CI service or distribution machinery is required.

## Reference tests in this milestone

- Result-envelope shape and the relationship between success, completion, and error codes.
- Admission bounds at capacity and one beyond.
- Same-ID same-payload duplicates while queued, dispatched, completed, and unknown.
- Same-ID changed-payload conflict.
- Expiration before dispatch without fencing.
- Expiration after dispatch, queued cancellation, and refusal of further UI dispatch.
- Late completion cannot silently remove a fence.
- Recovery requires old-runner retirement and a new generation.
- Stale-generation replies cannot finish a new command.
- Mutations remain blocked until a new inspection succeeds.
- A possibly partial mutation failure fences the session rather than returning to ready.
- Failed retirement cannot release a device lease.

The model has no timers or operating system integration. Supplying `oldRunnerRetired: true` is a
test input, not evidence that real XCTest teardown is complete. Production tests must establish the
external facts on which the policy relies.

## Required when the relevant implementation lands

| Area | Required fault/boundary evidence |
| --- | --- |
| Protocol | Fragmented headers/bodies, invalid lengths, depth/UTF-8 limits, slow clients |
| Authentication | Wrong/replayed tokens, cross-session identities, expired generations |
| Files | Symlinks, wrong owner/mode/type, partial files, disk full, no-clobber exports |
| Processes | Output flooding, failed spawn, hung exit, PID reuse, orphaned runner |
| Scheduling | Simultaneous admission, queue overflow, deadline at dispatch boundary |
| Recovery | Lost acknowledgements, disconnect during tap/type, late input after runner death |
| Snapshots | Oversized/deep trees, truncation, duplicate labels, stale/changed geometry |
| Artifacts | Interrupted PNG transfer, wrong count/digest, cache pressure, pinned files |
| App lifecycle | Multiple products, install failure, preservation of existing user data |
| Toolchains | Clean/reused builds under each exact supported Xcode/runtime pair |
| Agent use | Bounded bursts, long sessions, multi-simulator isolation, pause/resume |

Use deterministic seeded event sequences against the production transition core when it exists;
record seeds and failing traces. Combine that with actual simulator workflows. Neither model tests
nor fuzzing establish the absence of bugs or replace the public-API feasibility checks.

Milestones 7–9 evidence is recorded in
[the supervisor/UI report](../MILESTONES_7_9.md), including concurrent queue admission, duplicates,
secure-field redaction, artifact framing/publication, uncertain mutation recovery, stale references,
shared device leases, and exact-toolchain supervisor replacement.

Milestones 5–6 evidence is recorded separately in
[the combined runtime/helper report](../MILESTONES_5_6.md). It includes output flooding, timeout
escalation, owned-process reaping, fragmented frames, authenticated outward connections, exact-input
cache reuse, graceful/disconnected helper retirement, and live runs on both supported Xcodes.

## Review checklist before milestone 3

- Are the CLI's explicit targeting and recovery steps suitable for the backend-agent workflow?
- Is the initial budget of four sessions/eight waiting commands appropriate?
- Is retaining unknown outcomes across recovery, with no automatic retries, unambiguous?
- Are the local security boundary and mixed-toolchain restriction accurately described?
- Is the proposed helper connection direction acceptable, with verification deferred to milestone 6?

The accepted contract becomes the basis for implementation; schema changes must be deliberate and
documented rather than inferred from incidental behavior of the probe.
