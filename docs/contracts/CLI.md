# Production CLI contract, version 1 proposal

Product and executable: **ControlKit**. No lowercase alias or separate scripting language.
Examples below describe the proposed production API, not the current probe.

## Common behavior

- `ControlKit help`, `ControlKit help ui tap`, and `--help` at every command level.
- Help describes defaults, units, examples, outputs, errors, and side effects. It never starts a
  supervisor, resolves packages, boots a device, or reads runtime credentials.
- `--json`: one UTF-8 JSON result on stdout, including argument/validation errors. Diagnostics and
  progress go to stderr. `--help` takes precedence over `--json` and renders ordinary help.
- `--non-interactive`: never prompt. `--json` also implies noninteractive behavior.
- `--timeout <seconds>`: finite positive duration within the command's limits. It includes queue
  time and does not imply cancellation after dispatch.
- `--request-id <UUID>`: optional caller-chosen identity; otherwise the CLI creates one. Reusing it
  requests the same receipt within the same session and supervisor epoch, not another execution.
  It is not a durable idempotency key across supervisor restarts.
- `--project <directory>`: explicit repository/discovery root for project commands.
- `DEVELOPER_DIR` chooses Xcode; never call `xcode-select --switch`. Resolved toolchain identity is
  returned by `doctor` and session metadata.
- No hidden "current simulator" or "current session" file. UI commands require `--session`.
  Lifecycle commands require `--device`, unless `run` resolves a configured destination unambiguously.
- Long-form options are the documented agent interface. Unsupported options are errors.

## Commands and side effects

| Command | Inputs and output |
| --- | --- |
| `doctor` | Read-only environment/configuration diagnosis; report provenance and actionable findings |
| `setup` | Guided choices; explicit confirmation before downloads or configuration writes |
| `sim list` | Device identities, runtime/build, and state |
| `sim create` | Explicit runtime, device type, and name; return the new UDID |
| `sim boot` | Boot the chosen device and wait within the deadline; already booted is success |
| `sim shutdown` | Shut down the chosen device; respect any session owner |
| `app build` | Resolved project/workspace, scheme, configuration, and simulator destination |
| `app install` | `--path` to an existing simulator `.app`; verify platform and architecture |
| `app launch` | `--bundle-id`; activate if already running, otherwise launch; no implicit reset |
| `app logs` | `--device`, `--bundle-id`; bounded resolved-executable snapshot; no streaming |
| `app crashes` | `--device`, `--bundle-id`; bounded reports with exact simulator association |
| `app terminate` | Explicit app termination, not session or simulator termination |
| `session start` | `--device`, `--app`; attach only; return session, generation, epoch, and limits |
| `session list` | Owned sessions and states, not credentials |
| `session status` | `--session`; optionally `--request-id` for a non-replaying receipt query |
| `session recover` | Retire the old runner, establish a new generation, require observation |
| `session stop` | Stop owned automation; retain app data, app process, and simulator |
| `ui inspect` | Structured snapshot; optional `--screenshot` with separate capture timestamps |
| `ui find` | At most 16 exact matches with type, frame, hittability, and snapshot references |
| `ui screenshot` | PNG artifact metadata; optional explicit `--output` export |
| `ui tap` | Exactly one supported target selector |
| `ui type` | Explicit field selector and `--text` or `--text-stdin`; append, never implicit clear |
| `ui set-text` | Clear, replace, and verify one nonsecure field with a nonempty final value |
| `ui swipe` | Named container selector and finger-motion direction |
| `ui scroll` | Named scroll container and content direction; one bounded scroll gesture |
| `ui wait` | Selector plus `--state exists/absent/hittable`; bounded condition polling |
| `ui system-alert inspect` | Bounded foreground SpringBoard alert and button descriptors |
| `ui system-alert tap` | Exactly one enabled/hittable alert button by identifier or label |
| `logs` | Bounded/redacted diagnostics; follow requires an explicit finite duration |
| `run` | Compose validated preparation, build/install if needed, launch, and session attachment |

All device-mutating commands respect the same lease. Supplying only a device UDID cannot bypass
another session's ownership. While a session exists, such operations must explicitly name it.
Builds use separately owned derived-data directories and do not bypass the device lease for install.

`session start` does not create/boot a simulator or install/launch the app. `run` is the convenience
workflow for those effects. Updating an installed binary can terminate/relaunch the app; `run`
reports that explicitly. Only attach/observation promise no automatic relaunch.

Session and simulator lists are read-only. `setup` never silently accepts licenses, installs
certificates, downloads gigabytes, or runs arbitrary build-server commands. A project build can run
that repository's build scripts; document this trust boundary rather than describing it as read-only.

## Configuration

Precedence: explicit arguments → selected ControlKit profile → canonical `buildServer.json` →
unambiguous validated Xcode discovery. Never silently replace stale explicit configuration.

Only recognized Xcode metadata is reused from `buildServer.json`; arbitrary `argv` is never executed.
Discovery is bounded by the repository root and documented traversal limits. Missing metadata leads
to a setup walkthrough (or a structured list of required choices in noninteractive mode).
Additional shared settings may live in `controlkit.json`; secrets and machine-local runtime state may not.
Do not duplicate the build-server workspace/scheme merely to make a complete-looking profile.

Milestone 4's [discovery report](../MILESTONE_4.md) specifies the implemented profile schema,
filesystem boundary, and exact search rules. Its experimental command returns filesystem-only
metadata, not the validated Xcode result or production command envelope described here.

Milestones 7–9 implement production `session` and `ui` groups, including JSON envelopes, selectors,
receipts, explicit recovery, bounded screenshots, and waits. Milestones 10–12 implement production
`sim`, `app`, `doctor`, `setup`, `logs`, and `run` for the simulator-only MVP. Experimental probe
commands remain separate and do not fill production contracts.

## Targeting and inspection

Selectors:

- `--id`: exact accessibility identifier.
- `--label` with optional `--type`: exact label, no XPath or arbitrary predicate evaluation.
- `--ref`: locator hint scoped to a retained snapshot and helper generation.
- `--x` and `--y` for coordinate taps: finite **screen points**, with a required `--snapshot`.

Require exactly one selector family. Zero matches and multiple matches are distinct errors.
Never silently pick the first match. Typing requires an explicit text-field target, not whichever
field happens to be focused. Text is literal data, not shell/code.

Snapshot results include identity, capture time, app, generation, screen-point dimensions,
element type/identifier/label/value/enabled/selected/frame, and explicit truncation reasons.
Do not call a snapshot attribute `visible` when it merely means `exists`, within bounds, or hittable.
Do not serialize secure-field values. Raw element indices are not stable actionable identities.

Retain at most one actionable snapshot per session. Another inspection, UI mutation, lifecycle
change, recovery, or expiration invalidates its references. Resolve and revalidate a reference at
dispatch; reject stale, changed, or ambiguous targets. External UI changes can occur between any
observation and action: references are not a transactional lock on the app.

Coordinates also require matching app, generation, orientation, and screen dimensions. Unknown
orientation must be represented honestly, not populated by changing the device. Do not claim
rotation-safe coordinate targeting until public geometry validation can establish the mapping.

Screenshots report pixel dimensions and scale separately from element point coordinates. An
inspection and screenshot are not an atomic snapshot of an animating app. Never overwrite an
existing output file by default; publish completed files atomically and clean partial artifacts.

## Errors and exit status

| Exit | Meaning |
| --- | --- |
| 0 | Success, including help |
| 2 | Invalid arguments or configuration |
| 3 | Known operating failure, including locator failure and pre-dispatch expiry |
| 4 | Outcome unknown after dispatch; do not repeat the action |
| 5 | Internal/protocol failure; fail closed and diagnose |
| 130 | User interrupt; JSON completion metadata still distinguishes dispatched uncertainty |

Initial stable error vocabulary: `invalid_argument`, `configuration_missing`,
`configuration_ambiguous`, `unsupported_toolchain`, `toolchain_mismatch`, `device_busy`,
`session_not_ready`, `stale_generation`, `inspection_required`, `busy`, `deadline_exceeded`,
`cancelled`, `element_not_found`, `ambiguous_element`, `element_not_hittable`, `stale_reference`,
`request_id_conflict`, `result_expired`, `outcome_unknown`, `session_limit`, `resource_limit`,
`protocol_mismatch`.

The error string is for people; agents branch on `code` and completion metadata. A successful tap
means the automation action completed, not that a backend transaction succeeded.
