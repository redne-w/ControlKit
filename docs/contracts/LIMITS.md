# Initial production budgets

These are proposed admission limits, not measured platform guarantees. The small fixture validates
order of magnitude only. Revisit budgets with real-app evidence before advertising performance.
Reject impossible input as an operating error; do not use assertions as quota enforcement.

## Owned resources

| Resource | Initial limit | Rationale |
| --- | --- | --- |
| Active simulator sessions | 4 per supervisor | Bound runner/process and host pressure |
| UI operations | 1 per simulator | Avoid races and interleaved mutations |
| Waiting UI commands | 8 per session, 32 total | Burst tolerance without invisible backlog |
| Active Xcode builds | 1 | Bound CPU/memory and derived-data contention |
| Waiting build jobs | 2 | Explicit admission instead of unbounded spawning |
| Client connections | 32, at most 8 unauthenticated | Bound sockets and handshake work |
| Handshake payload | 4 KiB | Identities/capabilities, not application data |
| Control request | 64 KiB | Bounded parsing before authentication/dispatch |
| Control response | 2 MiB | Bounded snapshots and results |
| Binary chunk | 64 KiB | Incremental artifact transfer |
| Screenshot artifact | 32 MiB | Accommodate devices while bounding owned memory/disk |
| Input text | 16 KiB UTF-8 | Bound input work; reject oversized input, never truncate it |
| Identifier/label selector | 4 KiB UTF-8 | Bound validation and matching |
| Snapshot | 512 nodes, depth 32, 2 MiB total | Iterative, bounded extraction |
| Exact find result | 16 elements | Diagnose ambiguity without unbounded query output |
| System alert buttons | 8 | Narrow SpringBoard access to one foreground alert |
| Attribute text | 4 KiB UTF-8 per attribute | Report truncation explicitly, never silently |
| Actionable snapshots | 1 per session, max age 60 seconds | Simple reference ownership |
| Accepted requests | 10,000 per session or management epoch | Retain duplicate-detection receipts |
| Compact receipts | 16 MiB per registry | Bound metadata independently of large results |
| Full cached results | 16 per session, 4 MiB total | Old results may expire; receipts may not |
| Subprocess output | 8 MiB retained per operation | Drain both streams; rotate/discard after cap |
| Retained diagnostic logs | 16 MiB per session, 64 MiB total | No unbounded background logging |
| Stored artifacts | 256 MiB total, max age 24 hours | Evict only completed, unpinned artifacts |
| Helper build cache | 4 toolchain/input entries, 4 GiB total | Never evict a running helper's files |
| App derived-data cache | 4 configurations; 64 GiB and 1,048,576 entries total | Real Xcode graphs are large; no unsafe eviction |
| Repository discovery | 32 ancestor steps; 1,024 entries, depth 4 | No recursive or whole-machine crawl |
| Discovery configuration file | 64 KiB, JSON depth 32 | Bound parsing even for ignored fields |
| ControlKit profiles | 16, names at most 128 UTF-8 bytes | Bounded, explicit profile selection |
| Selected discovery setting | 4 KiB UTF-8 | Nonempty, no control characters |

Both count and byte limits apply; the first reached wins. Snapshots return `truncated` plus reasons
and visited/emitted counts. Truncated fields must not be reused as if they were exact selectors.
When no safe eviction is possible, reject new work rather than deleting live artifacts/receipts.
The tool must bound buffers while draining output, not periodically sample an ever-growing file.

Swift/framework allocations and XCTest snapshot construction are outside these owned budgets.
Do not claim to bound Apple's internal memory, CPU, or execution. An outer process guard and honest
failure semantics are required when a framework call blocks.

## Time and retries

| Operation | Default | Maximum |
| --- | --- | --- |
| UI command, including queue time | 30 seconds | 120 seconds |
| Condition wait | 10 seconds | 60 seconds |
| Helper startup/recovery | 120 seconds | 180 seconds |
| Simulator boot | 120 seconds | 300 seconds |
| App installation | 60 seconds | 300 seconds |
| Project build | 900 seconds | 1,800 seconds |
| App log snapshot | 60 seconds | 120 seconds |
| App crash scan | 30 seconds | 60 seconds |
| Connection handshake | 5 seconds | 5 seconds |
| Incomplete frame/transfer inactivity | 5 seconds | 5 seconds |
| Graceful shutdown | 5 seconds | 5 seconds |
| Termination escalation | 2 seconds TERM + 2 seconds KILL observation | 4 seconds |
| Session idle time | 10 minutes | 10 minutes |
| Session/helper hard lifetime | 30 minutes | 30 minutes |
| Empty supervisor idle lifetime | 2 minutes | 2 minutes |

App logs accept 1–3,600 seconds (default 60) and 1–512 entries (default 200).
Messages are limited to 4 KiB and the encoded result to 1 MiB. App crashes accept 1–86,400
seconds (default 3,600) and 1–32 reports (default 10). The nonrecursive scan examines at most
2,048 immediate `.ips` entries, reads regular no-follow files of at most 4 MiB, bounds each
returned exception summary to 4 KiB, and limits the encoded report collection to 1 MiB.

Filesystem discovery uses a 5-second default, 30-second maximum cooperative deadline (minimum 1 ms).
The milestone-4 implementation checks between filesystem operations; it cannot interrupt a blocked
filesystem call. This is not a hard wall-clock guarantee. See [measured scope](../MILESTONE_4.md).

Session hard lifetime includes all helper generations and is not reset by recovery. Before admitting
new work, ensure its budget does not exceed the remaining lifetime. At hard expiry, use stop/fence
semantics; do not pretend a forced timeout proves the action did not occur.

Startup may retry **once**, only after verified cleanup and before any UI command dispatch.
UI mutations have **zero automatic retries**. Read polling is explicit (`ui wait`), bounded to
300 samples and a minimum 200 ms interval, and always constrained by the original deadline.
Unknown outcomes never fall into a generic retry loop.

## Performance evidence to collect

Measure cold/warm startup; end-to-end and helper time separately; p50/p95/p99 with recorded sample
counts; peak owned queues/buffers; RSS; CPU; and disk under long runs. Include real screens, keyboards,
rotation, animations, and multi-simulator load. Enforce resource limits now; choose latency targets
only after those measurements. The current Just stress recipe is a sequential probe soak, not a
production performance qualification.
