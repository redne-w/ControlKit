# Session lifecycle and failure semantics

All transitions are synchronous, non-suspending functions over owned state. Process/network/timer
callbacks enqueue bounded events; they do not mutate session state directly. Effects carry the
identities needed to reject stale completions. A Swift actor alone does not make a transition atomic
across `await`.

Milestones 7–9 implement this boundary in `ControlKitSession`, with effects owned by bounded supervisor
workers. Live disconnect/recovery evidence is in
[the combined report](../MILESTONES_7_9.md).

## States

| State | Permitted work |
| --- | --- |
| `starting` | Readiness/version/authentication checks; no UI work |
| `ready` | Admit bounded UI work; dispatch one operation |
| `executing` | One operation in flight; later work may queue within its own deadline |
| `fenced` | No UI work; status, diagnostics, explicit recovery or stop only |
| `recovering` | Retire old runner, establish a new generation, complete handshake |
| `needsInspection` | Fresh inspection only; no mutations or condition waits |
| `stopping` | Cancel queued work and retire owned processes; no new UI work |
| `stopped` | Terminal; release lease only after owned execution is retired |

No implicit recovery after a possibly dispatched mutation. Known startup failures before dispatch
may retry within the explicit startup retry/deadline budget.

## Admission and execution

1. Validate/authenticate request, epoch, session, generation, operation, and limits.
2. Check an existing receipt before accepting a new action.
3. Validate phase and capacity; reserve receipt/queue storage atomically.
4. Queue with the original deadline. Do not extend it when it reaches the front.
5. Before dispatch, recheck cancellation, deadline, target, and snapshot validity.
6. Record dispatch intent before sending anything effectful. A send failure from this point may
   be uncertain even if no acknowledgement arrived.
7. On a valid terminal result, seal the receipt and choose the next permitted transition.

Per-session order is admission order, not wall-clock request timestamps. Parallel sessions may
operate different simulators using the pinned toolchain; limits also apply globally.
All requests affecting the same device, including lifecycle commands, obey the device lease.

## Timeouts and cancellation

- Before dispatch: remove from the queue, return `not_dispatched`; session remains usable.
- After dispatch: return `unknown`, fence, and fail queued requests as `not_dispatched`.
- Lost client connection after admission is not permission to replay or forget an action.
- Read-only operations can still leave the helper busy. A stalled inspection fences subsequent
  UI work until explicit recovery; a late result alone never removes the fence.
- Ctrl-C requests cancellation, waits only within the cancellation budget, and exits 130. The final
  JSON completion must still say `unknown` when cancellation cannot be established.
- Resource/decoding errors after dispatch follow the same rule; do not mislabel them as safe retries.

## Recovery

`session recover`:

1. Keep the device lease and fence. Never allow a second agent to drive the device during cleanup.
2. Cancel queued work. Preserve all completed/unknown receipts and invalidate snapshots.
3. Request helper shutdown, then terminate only verified owned processes if necessary.
4. Confirm old runner retirement before launching a replacement. If retirement cannot be confirmed,
   remain fenced and report the failure; do not return a successful recovery.
5. Increment generation; start/authenticate the replacement within the startup budget.
6. Enter `needsInspection`. Return the unknown command receipt and explicit recovery state.
7. A successful fresh inspection transitions to `ready`. A failed/truncated-unusable inspection
   does not remove the observation requirement.

Retiring the runner is **not** proof of rollback or absolute cancellation inside Apple's automation
services. It cannot undo gestures already submitted or app/network effects they triggered. Recovery
is an explicit request to establish a new control session, not a claim that the old action failed.
Production qualification must test late-input behavior across runner death. If public APIs cannot
establish acceptable execution isolation, stop and revisit the design before advertising safe
automatic continuation.

Do not relaunch/activate the target app merely to make recovery appear successful. If it is no longer
foreground, return that condition and require an explicit lifecycle action. Preserve app data.

## Shutdown and supervisor failure

Stop cancels queued work. An active action is allowed only a bounded grace period; unresolved work
becomes unknown. Keep the lease until runner retirement is confirmed. Stop is idempotent for an
already stopped session; it never implies app termination or simulator shutdown.

Supervisor restart creates a new epoch. Never adopt old in-flight work as fresh commands. Reconcile
owned processes using protected launch records and identity stronger than PID alone; unknown or
unverifiable ownership blocks automatic cleanup. Never kill a process merely because its name
contains `xcodebuild`.

Abandoned sessions have idle and hard lifetimes. Expiration uses the same stop/fence rules as an
explicit stop. A heartbeat or status poll does not keep a session alive indefinitely.

## Operation safety examples

| Event | Expected consequence |
| --- | --- |
| Queue is full | `busy`, no dispatch, no hidden overflow queue |
| Queued deadline expires | `not_dispatched`; later requests retain their own deadlines |
| Disconnect after tap submission | `unknown`, fence; never repeat tap |
| Old-generation success arrives | Ignore for state changes; record bounded diagnostics |
| Duplicate ID, same payload | Return receipt; no second execution |
| Duplicate ID, changed payload | `request_id_conflict` |
| Recovery cannot stop old runner | Remain fenced, retain lease |
| Fresh recovery inspection fails | Remain `needsInspection` |
| Snapshot's layout/generation changes | `stale_reference`, no action |
| Known missing element before tap | `finished` locator error, no UI effect, session remains usable |
| Typing fails after some characters | Unknown/possibly partial mutation, fence and inspect |
