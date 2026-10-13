# ControlKit

Native iOS simulator automation for engineers and agents, implemented in Swift with a separate
XCTest helper. Public XCTest APIs only; no Appium, WebDriverAgent, or idb dependency.

**Status: milestones 10–12 — complete simulator-only MVP, awaiting final review.**
Milestones 1–9 are approved. Production simulator/app lifecycle, doctor/setup/run orchestration,
sessions, UI automation, bounded logs, local acceptance, and an agent skill are implemented.

- [Design and milestones](docs/PLAN.md)
- [Milestone 4 discovery rules, configuration, and evidence](docs/MILESTONE_4.md)
- [Milestones 5–6 runtime, helper transport, and measured evidence](docs/MILESTONES_5_6.md)
- [Milestones 7–9 supervisor, UI safety, and measured evidence](docs/MILESTONES_7_9.md)
- [Milestones 10–12 app lifecycle, orchestration, and final evidence](docs/MILESTONES_10_12.md)
- [Milestone 3 foundation and package boundaries](docs/MILESTONE_3.md)
- [Approved milestone 2 contract](docs/contracts/README.md)
- [Milestone 1 results and limitations](docs/MILESTONE_1.md)
- [Xcode 27 verification](docs/XCODE_27.md)
- [Implementation rules](AGENTS.md)

## Requirements

- macOS with full Xcode. Verified with **26.4.1 (17E202)** and **27.0 (27A266a)** on Apple silicon.
- A compatible installed iOS simulator runtime. Verified with **iOS 26.4.1 (23E254a)**.
- [Just](https://just.systems) for the development recipes below; verified with Just 1.58.0.
- An iOS 27 runtime is **not** installed or tested. Toolchain and runtime versions are separate.

Select Xcode per shell without changing the machine's global configuration:

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
just                  # List documented development recipes
just doctor
just cli help
just cli help probe request
just cli probe request --help
```

Swift Argument Parser 1.6.1 is the sole third-party implementation dependency, pinned in the package
and lockfile. Just is a development convenience, not a dependency of the built CLI. Python is not
required. `just --show <recipe>` displays the underlying commands.

Recipes isolate compiler outputs under `.build/toolchains/<Xcode-build>/`. They honor `DEVELOPER_DIR`
and never switch global Xcode selection. Stop active probe runs before changing toolchains:
CoreSimulator can refresh its shared service when a different Xcode invokes `simctl`.

## Local checks

From the repository root:

```sh
just check
just test
just test-release
just test-seeded 42   # Replay generated reference-model scenarios
just source-check
just build release
just format-check
just help-check
just discovery-check # JSON and exit-status workflow, including the checked-in Xcode project
just xcode-check     # Bounded Xcode validation of the checked-in fixture metadata
just install-check   # Tests installation with temporary homes, not your shell configuration
just acceptance <dedicated-udid>
just acceptance-soak <dedicated-udid> 3
```

`check` runs source/package checks, formatting, debug and release tests, a release CLI build, nested
help, discovery and installation checks, and the simulator fixture/helper build. It does not boot
or erase a simulator or edit your shell configuration.
`sh Tools/check.sh` remains a compatibility entry point. `just format` edits Swift sources in place.

`source-check` enforces 100-column lines and 70-line declarations using the selected compiler's
parse output, not brace-counting. Semantic TigerStyle rules still require review.

## Try repository discovery

No simulator, helper, or credentials are needed:

```sh
just cli help probe discover
just probe-discover --project . --scheme ControlKitProbe --configuration Debug
just probe-discover --project /path/to/your/repo --profile backend
```

Discovery uses canonical `buildServer.json` without executing its `argv`, plus optional `controlkit.json`
profiles and explicit overrides. It returns JSON with the chosen container, field provenance,
findings, and required choices. Missing choices, stale paths, ambiguity, and limits exit nonzero.
It never chooses the first of several projects or silently replaces stale configuration.

**`filesystem_only` is not build validation.** Scheme/configuration validation needs milestone 5's
bounded Apple-tool runner; pass `--validate-xcode` to exercise it. Guided `setup` remains milestone
11. The experimental command does not implement the production result envelope. See the
[discovery report](docs/MILESTONE_4.md) for the profile schema, traversal rules, and limitations.

## Try simulator and helper lifecycle

These remain experimental adapters over the production runtime libraries:

```sh
just cli help probe sim
just cli probe sim list
just cli probe sim boot --device <dedicated-udid>
just helper-check <dedicated-udid>
just cli probe sim shutdown --device <dedicated-udid>
```

`sim create` requires exact runtime and device-type identifiers; it never guesses defaults.
Mutations use explicit UDIDs and retained ownership fences. `helper-check` builds or reuses the
exact-toolchain helper cache, keeps launch credentials in an owner-only directory outside the
repository, accepts an authenticated outward loopback connection, pings, stops, and verifies both
the owned `xcodebuild` child and authenticated XCTest runner have retired.

Use `just runtime-smoke <dedicated-udid>` for graceful startup, cache reuse, disconnected-helper
retirement, and shutdown. It mutates that simulator. See the
[milestones 5–6 report](docs/MILESTONES_5_6.md) before relying on its scope or failure semantics.

## Local install

```sh
just install-local
```

This builds a release binary, installs **`~/.local/bin/ControlKit`**, and adds that directory to PATH
in the startup files for your `$SHELL`:

- **zsh:** `${ZDOTDIR:-$HOME}/.zshrc`.
- **bash:** `.bashrc` and the first existing login file (`.bash_profile`, `.bash_login`, `.profile`);
  creates `.bash_profile` only when none exists.
- **fish 3.2+:** `${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/controlkit.fish`.

Existing configuration is preserved, including symlinked profiles. Re-running the installer does not
append the same PATH command again, and sourcing it repeatedly does not duplicate the PATH entry.
**Open a new shell** afterward, or run the PATH command printed by the installer in your current
shell; a child process cannot update its parent's environment. You can then run `ControlKit help`.
Already-running apps and agents keep their inherited environment; they can use
`~/.local/bin/ControlKit` directly until their PATH is updated.

`just install-local <prefix>` installs `<prefix>/bin/ControlKit` and configures that directory instead.
It also installs helper source/project inputs and the `ios-use-controlkit` skill under
`<prefix>/share/ControlKit`, so sessions do not depend on the development checkout. No sudo, global shell
files, packaging, signing, or distribution setup is involved.

## Diagnose and configure a repository

```sh
ControlKit doctor --project . --json
ControlKit setup --project . --json
```

ControlKit prefers canonical `buildServer.json`. `setup` reports missing choices without writing by
default. Interactive `--write` walks through missing project/workspace, scheme, and configuration,
then asks for confirmation. Automation must use `--non-interactive --yes` with every required choice.
Only explicit shared settings are written to `controlkit.json`; credentials and device state are rejected.

## Build and run

```sh
ControlKit sim list --json
ControlKit app build --project . --profile agent --json
ControlKit run --project . --profile agent --device <dedicated-udid> --json
```

`app build` validates one simulator product and uses owned derived data. Repository build scripts are
trusted code. `run` composes build (or `--app-path`), boot, install, launch, and session start while
returning every completed step if a later step fails. App installation may replace/terminate the
installed binary but never clears app data. `--timeout` applies to the complete workflow, including
slow Xcode metadata discovery; it is not reset between phases. `run` uses its explicit simulator as
the Xcode destination; standalone `app build` can do the same with `--device`.

## Sessions and UI automation

To operate an already prepared app directly:

```sh
ControlKit sim boot --device <dedicated-udid> --json
ControlKit app install --device <dedicated-udid> --path path/to/App.app --json
ControlKit app launch --device <dedicated-udid> --bundle-id com.example.app --json
ControlKit app logs --device <dedicated-udid> --bundle-id com.example.app --since 60 --limit 200 --json
ControlKit app crashes --device <dedicated-udid> --bundle-id com.example.app --since 3600 --limit 10 --json

session=$(ControlKit session start \
  --device <dedicated-udid> --app com.example.app --json |
  plutil -extract data.session.id raw -o - -)

ControlKit ui inspect --session "$session" --generation 1 --json
ControlKit ui find --session "$session" --generation 1 --type 49 --json
ControlKit ui tap --session "$session" --generation 1 --id submit --json
ControlKit ui type --session "$session" --generation 1 --id email --text-stdin --json
ControlKit ui set-text --session "$session" --generation 1 --id endpoint --text /v1/example --json
ControlKit ui screenshot --session "$session" --generation 1 --output screen.png --json
ControlKit ui system-alert inspect --session "$session" --generation 1 --json
ControlKit session stop --session "$session" --json
```

Unified logs expose a process image, not a bundle identifier. `app logs` resolves the installed
bundle's executable and reports `scope` plus `bundleAssociationVerified: false`; apps sharing that
executable name are not distinguishable. Crash reports require an exact selected-simulator path or
coalition identity and report `deviceAssociationVerified: true`.

The automatically managed local supervisor admits at most four sessions, one per simulator. Commands
are serialized per session with eight waiting slots. Reusing `--request-id` returns the existing
receipt/result and never dispatches again. A timeout, interrupt, or disconnect after dispatch returns
`outcome_unknown`, fences the session, and requires:

```sh
ControlKit session recover --session "$session" --json
ControlKit ui inspect --session "$session" --generation 2 --json
```

Recovery retires the old runner and does not replay the action or relaunch the app. See the
[milestones 7–9 report](docs/MILESTONES_7_9.md) for selectors, snapshot/artifact bounds, security,
failure semantics, and the remaining supervisor-crash limitation.

## Live XCTest proof

Use a dedicated simulator: the harness installs and relaunches `dev.controlkit.fixture`.
Do not point it at a simulator whose current foreground state you need to preserve.

```sh
# This creates a new test simulator; retain its returned UDID.
just probe-create
just probe-boot <udid>
just probe-smoke <udid>
just probe-stress <udid> 3 20
just session-smoke <udid> # Mutating production-session acceptance workflow
just probe-shutdown <udid>
```

`probe-create` defaults to iPhone 17 / iOS 26.4; runtime and device parameters are identifier
suffixes, for example `just probe-create iOS-26-4 iPhone-17 "ControlKit Development"`.
Recipes require an explicit UDID, never whichever simulator happens to be booted.
`probe-smoke`, `probe-stress`, and `probe-serve` build their prerequisites.

The harness:

1. Installs/launches the fixture and starts the independent XCTest runner.
2. Launches a separate CLI process for every command.
3. Checks navigation, taps, Unicode input, scrolling, screenshots, and structured errors.
4. Restarts the helper and checks that in-memory app state survives.
5. Times out a mutation, forcibly terminates the helper, and verifies recovery without replay.
6. Writes a credential-free `summary.json` with observed latency.

The test runtime directory also contains credentials and raw execution logs. Keep it private;
do not commit or share those files. The harness does not delete simulators or perform distribution.
Just creates a fresh owner-only directory outside the repository and prints its path. Logs are
retained for local diagnosis. Stress is a **bounded sequential soak**, not concurrent-agent
qualification: 1–10 smoke rounds, each with 0–100 extra inspections.

## Try the helper manually

With a dedicated simulator already booted, start the helper in one terminal:

```sh
just probe-serve <udid>
```

It installs/relaunches the fixture and prints a **private connection-file path**, never the token.
In another terminal using the same `DEVELOPER_DIR`:

```sh
connection="/private/.../connection.json"  # Use the path printed above
just probe-request "$connection" inspect
just probe-request "$connection" tap --id fixture.open
just probe-request "$connection" tap --id fixture.increment
just probe-request "$connection" type --id fixture.input --text "Hello café 👋"
just probe-request "$connection" tap --id fixture.dismiss
just probe-request "$connection" swipe --id fixture.scroll
just probe-request "$connection" screenshot --output screen.png
just probe-request "$connection" stop
```

This is shorthand for `ControlKit probe request <operation> --connection <file> ...`.
The connection file must be an owner-only regular file. Advanced use can still supply `--port`
and `CONTROLKIT_PROBE_TOKEN` through the environment; do not put tokens in shell arguments or the repo.
The probe limits its command loop to 10 minutes and 200 commands; this does not bound Apple's
internal execution. See the milestone-1 limitations. This prototype does not manage concurrent agents.

Requests always produce JSON; failures exit nonzero. Argument syntax errors use Argument Parser's
standard diagnostics. `swipe` moves the finger upward. `type` appends after focusing a plain text
field. Identifiers match exactly, and ambiguous matches fail.

The client deadline is not a cancellation guarantee. An `outcome_unknown` response means that an
action may have executed. **Never blindly replay it.** This probe has no production recovery/session
contract; recover the runner explicitly and inspect the app before further mutations.
