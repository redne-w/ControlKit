# Milestones 5–6 — bounded runtime and helper lifecycle

Status: implemented together with owner approval and ready for review. Stop before milestone 7.

## Delivered

- `ControlKitProcess`: synchronous `posix_spawn` ownership with literal argv/environment, nonblocking
  concurrent stdout/stderr draining, one combined 8 MiB retained-output cap, finite deadlines,
  cancellation, process-group TERM/KILL escalation, and child reaping without signaling a reaped PID.
- `ControlKitRuntime`: exact `DEVELOPER_DIR` identity, bounded `simctl` list/create/boot/shutdown,
  retained mutation fences, bounded Xcode scheme/configuration validation, private files/locks,
  exact-input helper cache, launch configuration, readiness, and verified retirement.
- `ControlKitWire`: loopback-only host listener held from ephemeral bind through accept; outward helper
  connection; framed, bounded JSON; launch token; epoch/session/generation/launch/device identity;
  capability negotiation; lifecycle ping/stop; finite read/write/incomplete-frame deadlines.
- Independent `Helper/ControlKitRuntime.xcodeproj`, containing only public XCTest lifecycle plumbing.
  It does not launch a target app or implement UI operations.
- Experimental `ControlKit probe sim ...`, `probe discover --validate-xcode`, and
  `probe helper-check` adapters, each with nested help. These are not the final production commands.

## Process and mutation semantics

Commands require absolute executables/directories, at most 128 argv and 128 environment entries,
64 KiB total command text, 16 KiB per field, a 1 ms–30 minute deadline, and at most 8 MiB combined
retained output. Pipes are drained after the retention cap to prevent child deadlock. Build diagnostics
may be discarded after 8 MiB only when exit status and independently validated output files determine
success; JSON-producing commands reject truncated output.

Each child starts in a new owned process group. Timeout/cancel sends TERM, waits 2 seconds, sends KILL,
and requires observed child exit within another 2 seconds. The leader remains unreaped until group
cleanup, preventing its process-group ID from being reused during signaling. ControlKit never finds or
kills a process by name.

Simulator mutations are explicit by UDID. `boot`/`shutdown` are idempotent only after observing the
already-final state. `create` has no retry. Before dispatch, the operation writes an owner-only record;
uncertain failure retains it and later commands fail closed. This per-invocation foundation is not the
milestone-7 supervisor registry: there is deliberately no automatic adoption or stale-PID recovery.

`xcodebuild -list -json` validates scheme selection. `-showBuildSettings -json` identifies every
participating project, which must stay under the repository root; each project is listed separately
to validate the selected configuration. Package auto-resolution is disabled. These read-oriented
commands can still cause Xcode cache activity; they are not described as filesystem-only.

## Cache and private state

The helper cache key hashes:

- canonical developer directory, Xcode version/build, and simulator SDK build;
- Debug/generic-simulator/unsigned/protocol constants;
- the helper project/scheme, helper source, and all three shared wire sources.

Inputs are hashed before and after build. A cache entry becomes reusable only after successful build,
bounded cache scan, unchanged input hash, and exclusive creation of a completion marker containing
the key. At most four entries and 4 GiB/16,384 entries/depth 32 are admitted. There is no automatic
eviction because milestone 6 has no long-lived supervisor that can prove entries are unpinned.
Incomplete entries remain diagnostic evidence and block reuse.

Runtime state is in `${TMPDIR}/ControlKit-runtime`, outside the source repository, mode 0700. Credential
files are descriptor-relative, no-follow, owner-only regular files with mode 0600 and link count one.
Each run retains its private configured xctestrun/result bundle for diagnosis, bounded to 32 runs and
256 MiB (the approved stored-artifact budget). Later supervisors mark a run complete only after
authenticated runner retirement and evict completed runs oldest-first when either bound is reached.
Active and retirement-unconfirmed runs remain diagnostic evidence and can make startup fail closed.

## Handshake and retirement

The host binds loopback first and retains the listening socket. A fresh 256-bit random token is placed
only in the private xctestrun environment, never argv, JSON output, repository files, or normal logs.
The helper connects outward and sends protocol version, token, supervisor epoch, session ID, positive
generation, launch ID, simulator UDID, helper PID, and exact lifecycle capabilities. The host accepts
at most eight attempts and validates all fields before sending readiness.

Frames use four-byte big-endian length including a one-byte kind. Handshake is 4 KiB; lifecycle control
is 64 KiB. Limits are checked before allocation. UTF-8, JSON depth eight, duplicate/unknown fields,
frame kind/order, identity, operation, and remaining deadline are validated. Reads and writes have a
five-second inactivity/deadline bound. No reconnect or request replay exists.

Retirement first sends lifecycle stop when possible, closes the connection, and waits a bounded grace.
Disconnect/error cancels the owned `xcodebuild` group. An authenticated runner PID is accepted only
when same-UID process metadata and executable path match the selected simulator's
`ControlKitRuntime-Runner`. ControlKit records PID start time, then requires that exact process identity to
disappear or become a zombie. Exited `xcodebuild` alone is not proof. Failure retains the device fence.

This establishes lifecycle plumbing only. It does not implement production UI dispatch, receipt
deduplication, sessions, binary artifacts, or the Unix-socket CLI/supervisor protocol.

## Measured evidence

Machine: macOS 26.7, Apple silicon, dedicated simulator
`96E15F23-38CB-4291-9A8D-649EF6861ACA`, iOS 26.4.1 runtime.

- Xcode 27.0 build `27A266a`, simulator SDK build `24A430`: cold helper build, authenticated outward
  connection, ping, graceful stop, cache reuse, forced post-ping disconnect, runner retirement,
  simulator boot/shutdown all passed.
- Xcode 26.4.1 build `17E202`, simulator SDK build `23E252`: the same cold/reused/graceful/disconnect
  sequence passed. Its cold xcodebuild diagnostics exceeded 8 MiB; output remained drained/bounded,
  and success required zero exit plus complete/cache/input validation.
- A previously installed `dev.controlkit.fixture` data container remained present after helper runs and
  simulator shutdown/reboot. The lifecycle helper did not launch/reset that target app.
- Unit tests exercise output flooding on both streams, spawn failure, pre-spawn cancellation,
  timeout escalation, orphaned pipe writers, exact cache hashes, private modes/symlinks, retained
  fences, loopback sockets, fragmented/truncated/oversized/wrong-kind frames, wrong token/device/
  launch identity, invalid UTF-8, duplicate/unknown/deep JSON, and bounded Xcode output parsing.

The complete local `just check` passed under Xcode 26.4.1 and 27.0. Each debug/release invocation
ran 77 test functions (plus parameterized cases and 1,280 deterministic model scenarios).
The live runtime smoke is intentionally separate because it boots and mutates an explicit simulator.

## Not measured or guaranteed

- iOS 27 runtime, physical devices, production apps, multi-simulator concurrency, burst/soak workloads.
- Production supervisor restart/adoption, session queues, receipts, UI effects, screenshots/artifacts.
- Same-UID malicious-process isolation. Tokens prevent accidental/wrong-launch admission, not a user
  process that can inspect another same-user process or its private files.
- Hard cancellation inside Apple frameworks or rollback of effects already submitted by Apple tools.
- Automatic cache/runtime cleanup. Bounds fail closed until an operator inspects/removes old evidence.

Proceed next to milestone 7 only after review.
