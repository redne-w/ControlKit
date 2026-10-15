# ControlKit

ControlKit is a command-line tool for automating iOS apps in the simulator. It builds, installs,
and launches your app, then lets you inspect and drive its UI from a terminal or an AI agent.
It uses only public XCTest APIs, with no Appium, WebDriverAgent, or idb.

## Features

- Build, install, launch, and terminate apps on a chosen simulator
- One command (`run`) from source checkout to a ready automation session
- Inspect the accessibility tree, find elements, tap, type, swipe, scroll, wait, and screenshot
- Handle iOS system alerts
- Read app logs and crash reports
- JSON output for scripts and agents, with safe retries via `--request-id`
- Local diagnostic logs and one-command bug reports
- An agent skill (`plugins/ios/skills/ios-use-controlkit`)

## Requirements

- macOS 15 or later on Apple silicon
- Xcode 26 or later, with an iOS simulator runtime installed
- [just](https://just.systems), only for building from source

ControlKit uses the Xcode selected by `DEVELOPER_DIR` (or `xcode-select`) and never changes it.

## Installation

```sh
brew install redne-w/controlkit/controlkit
ControlKit --version
```

To build from source instead, clone the repository and run `just install`. This installs
`ControlKit` to `~/.local/bin` and adds that directory to your shell's `PATH` (zsh, bash, or
fish); open a new terminal afterward. Use `just install /some/prefix` to install elsewhere.

## Usage

Use a simulator dedicated to automation, since ControlKit will boot it and install apps on it.
Create one with `just simulator` or `xcrun simctl create`, or find one with `ControlKit sim list`.

Check your environment and project, then build, launch, and attach in one step:

```sh
cd path/to/your/app
ControlKit doctor --project .
ControlKit run --project . --scheme MyApp --configuration Debug --device <udid> --json
```

`run` prints a session ID and generation number. Use them to drive the UI:

```sh
ControlKit ui inspect --session <session> --generation 1 --json
ControlKit ui tap --session <session> --generation 1 --id loginButton --json
ControlKit ui type --session <session> --generation 1 --id email --text me@example.com --json
ControlKit ui screenshot --session <session> --generation 1 --output screen.png --json
ControlKit session stop --session <session> --json
```

To avoid passing `--scheme` and `--configuration` every time, save them for the repository:

```sh
ControlKit setup --project . --scheme MyApp --configuration Debug --write
```

### Commands

| Command | Purpose |
| --- | --- |
| `doctor` | Check Xcode, simulators, and repository settings |
| `setup` | Save build settings to `controlkit.json` |
| `run` | Build, boot, install, launch, and start a session |
| `sim` | `list`, `create`, `boot`, `shutdown` simulators |
| `app` | `build`, `install`, `launch`, `terminate`, `logs`, `crashes` |
| `session` | `start`, `list`, `status`, `recover`, `stop` automation sessions |
| `ui` | `inspect`, `find`, `tap`, `type`, `set-text`, `swipe`, `scroll`, `wait`, `screenshot`, `system-alert` |
| `logs` | Show recent events for a session |
| `cache clean` | Remove cached app and helper builds when a cache is full |
| `report` | Package diagnostics into a zip file for a bug report |

Every command has help: `ControlKit help <command>` or `ControlKit <command> --help`.

### When a command times out

If a command times out or is interrupted after it was sent, the result is `outcome_unknown`, which
means the action may or may not have happened. ControlKit never retries it automatically. Recover
the session and inspect the screen before continuing:

```sh
ControlKit session recover --session <session> --json
ControlKit ui inspect --session <session> --generation 2 --json
```

## Reporting problems

Run this from the repository you were automating and send the zip file it creates:

```sh
ControlKit report
```

The report contains ControlKit's logs from `~/Library/Logs/ControlKit`, output from failed Xcode
and simulator commands, recent ControlKit crash reports, your macOS, Xcode, and simulator versions,
and `doctor` output. Passwords, tokens, and typed text are removed and your home folder is shown
as `~`. Project paths and build output are kept, so check the file before sharing it outside your
team. Nothing is sent anywhere automatically.

## Development

```sh
just              # list recipes
just build        # build a debug binary
just test         # run unit tests
just check        # all checks that don't need a simulator
just format       # format Swift sources
just acceptance <udid>   # end-to-end tests; boots and modifies that simulator
```

Build output goes to `.build/toolchains/<Xcode build>/`, so different Xcode versions never mix.

To release, bump the version with [sheepit](sheepit.toml), which commits, tags `vX.Y.Z`, and
pushes. The tag runs `.github/workflows/release.yml`, which builds, tests, and attaches
`controlkit-vX.Y.Z-macos-arm64.tar.gz` to a GitHub release. Then update `url` and `sha256` in
the [Homebrew tap](https://github.com/redne-w/homebrew-controlkit).

## License

MIT. See [LICENSE](LICENSE).
