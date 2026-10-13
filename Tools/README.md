# Local tools

The root `justfile` is the development entry point. Run `just` for the documented recipe list and
`just --show <recipe>` to inspect a command. `check.sh` forwards to `just check`; `help-check.sh`
checks the CLI's root and nested help without reading credentials or starting a helper.

`check-source.sh` compiles the development-only `SourceCheck.swift` auditor using the selected
toolchain. It checks source limits and package dependencies, with negative self-tests and an actual
oversized-function compiler fixture. Run through `just source-check`. Compiler parse output is not a
production dependency; changes to its format require reviewing this local checker.

`just test-release` exercises optimized code. `just test-seeded <seed>` replays deterministic model
scenarios without a simulator or real sleeps. These are distinct from live `probe-stress` runs.

`just install-local` uses `install-local.sh` to install into `$HOME/.local/bin` (or `<prefix>/bin`)
and append idempotent PATH setup for the user's zsh, bash, or fish startup files. It never sources
user configuration or changes the invoking shell's environment. Bash login-file precedence is
preserved; zsh's `ZDOTDIR` and fish's `XDG_CONFIG_HOME` are honored.

`just install-check` exercises the real binary with temporary home directories under `.build/`.
It checks all Bash login-file choices, zsh and fish when installed, repeated installation/sourcing,
symlink preservation, custom prefixes, unusual path characters, and invalid input. This check is
part of `just check` and does not change your actual dotfiles.

`ProbeSmoke.swift` is the milestone-1 integration harness. It requires the built CLI, built fixture,
built helper, and a dedicated booted simulator. Run it with `--help` for its arguments.

The Just recipes select toolchain-specific products via `CONTROLKIT_PROBE_CLI` and
`CONTROLKIT_PROBE_PRODUCTS`. Direct script use defaults to the original `.build/debug/ControlKit` and
`.build/probe-xcode/Build/Products`; prefer Just so outputs from different Xcodes do not mix.

| Recipe | Behavior |
| --- | --- |
| `probe-smoke <udid>` | One end-to-end interaction/restart/fault run |
| `probe-stress <udid> [rounds] [inspections]` | Sequential soak; 1–10 rounds, 0–100 extra reads each |
| `probe-serve <udid>` | Manual helper, up to 10 minutes; prints a private connection-file path |
| `probe-request <connection> <operation> [args...]` | Separate CLI process; JSON stdout |

These commands install/relaunch the fixture. They are not production session or build orchestration.
The smoke/soak run injects a timed-out tap that may still apply; it never replays that mutation.
Manual mode does not automatically recover or fence after uncertainty: stop and inspect deliberately.

It launches separate CLI processes for each operation. Runtime credentials and logs belong in a new
private temporary directory outside the repository. The directory is retained for diagnosis; never
publish its credential-bearing configuration or raw XCTest logs. Tokens expire when their helper
stops. The credential-free `summary.json` is suitable for recording measurements.

The harness may install/relaunch only the fixture app and deliberately terminate its helper during
fault tests. It never erases or deletes a simulator. Normal tests use element/state observations,
not arbitrary waits. The fault test's short delay deliberately creates an interruption window.

No CI, distribution packaging, or global Xcode changes are part of these tools.
