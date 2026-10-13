---
name: ios-use-controlkit
description: Use whenever an agent needs to build, launch, inspect, screenshot, tap, type, scroll, or test an app in an iOS simulator with ControlKit.
---

# ios-use-controlkit

Use ControlKit's bounded simulator-only workflow. Do not use Appium, idb, private XCTest APIs, physical
devices, or a "current simulator" shortcut. Keep one session and its returned generation throughout a
task. Never replay a request whose completion is `unknown`.

## Pre-flight

```bash
ControlKit doctor --project . --json
ControlKit sim list --json
```

If repository metadata is incomplete, prefer canonical `buildServer.json`. Run:

```bash
ControlKit setup --project . --json
```

Read its findings. For an explicit noninteractive profile:

```bash
ControlKit setup --project . --xcode-project App.xcodeproj \
  --scheme App --configuration Debug --profile-name agent \
  --write --non-interactive --yes --json
```

Do not place credentials, device UDIDs, or machine-local state in `controlkit.json`.

## One-command preparation

Use an explicitly dedicated simulator UDID:

```bash
result=$(ControlKit run --project . --profile agent --device "$UDID" --json)
session=$(printf '%s' "$result" | plutil -extract data.session.id raw -o - -)
generation=$(printf '%s' "$result" | plutil -extract data.session.generation raw -o - -)
```

`run` builds, boots, installs, launches, and starts automation. Repository build scripts are trusted
code. Pass `--app-path path/to/App.app` to skip the build.

## Observe, improvise, and interact

```bash
ControlKit ui inspect --session "$session" --generation "$generation" --json
ControlKit ui find --session "$session" --generation "$generation" --type 49 --json
ControlKit ui tap --session "$session" --generation "$generation" --id submit --json
printf '%s' 'literal text' |
  ControlKit ui type --session "$session" --generation "$generation" \
    --id email --text-stdin --json
printf '%s' '/mobile-arch-service/v1/flow/sample' |
  ControlKit ui set-text --session "$session" --generation "$generation" \
    --id endpoint --text-stdin --json
ControlKit ui scroll --session "$session" --generation "$generation" \
  --id content.scroll --direction down --json
ControlKit ui wait --session "$session" --generation "$generation" \
  --id result --state exists --timeout 10 --json
ControlKit ui screenshot --session "$session" --generation "$generation" \
  --output /tmp/controlkit-result.png --json
```

Selectors are exact:

- `--id VALUE`
- `--label VALUE [--type INSPECTED_NUMERIC_TYPE]`
- `--type INSPECTED_NUMERIC_TYPE`
- `--ref VALUE --snapshot UUID`
- `--x POINT --y POINT --snapshot UUID`

Never choose the first ambiguous element. Re-inspect after navigation/mutation before reusing a
reference or coordinate. `scroll` direction means content motion; `swipe` means finger motion.
Secure-field values are intentionally absent from inspection JSON.

Use `ui find` to refine an ambiguous selector or discover an unlabeled field by numeric type. It
returns at most 16 matches and never chooses one. Use `ui set-text` when the final nonsecure field
value must replace existing content; unlike `ui type`, it verifies the resulting value.

For a foreground iOS permission alert:

```bash
ControlKit ui system-alert inspect --session "$session" --generation "$generation" --json
ControlKit ui system-alert tap --session "$session" --generation "$generation" \
  --label Allow --json
```

System-alert commands expose only SpringBoard alerts and their buttons, not general system UI.

## Request identity and uncertainty

Supply a UUID when an agent may lose its CLI response:

```bash
request=$(uuidgen)
ControlKit ui tap --session "$session" --generation "$generation" \
  --id submit --request-id "$request" --json
ControlKit session status --session "$session" --request-id "$request" --json
```

The same ID and same parameters return the existing receipt/result and never execute twice. Changed
parameters return `request_id_conflict`.

If completion is `unknown`, **do not repeat the action**:

```bash
recovery=$(ControlKit session recover --session "$session" --json)
generation=$(printf '%s' "$recovery" |
  plutil -extract data.session.generation raw -o - -)
ControlKit ui inspect --session "$session" --generation "$generation" --json
```

Mutations remain blocked until that inspection succeeds. Recovery does not relaunch the app or undo
network/app effects already caused by the uncertain action.

## Diagnostics and cleanup

```bash
ControlKit logs --session "$session" --json
ControlKit app logs --device "$UDID" --bundle-id com.example.app \
  --since 60 --limit 200 --json
ControlKit app crashes --device "$UDID" --bundle-id com.example.app \
  --since 3600 --limit 10 --json
ControlKit session stop --session "$session" --json
ControlKit app terminate --device "$UDID" --bundle-id com.example.app --json  # only if desired
ControlKit sim shutdown --device "$UDID" --json                               # only if dedicated
```

Stopping a session preserves the app process, app data, and simulator. Always stop the session when
finished so its lease and authenticated XCTest runner retire cleanly.

When a ControlKit failure is unexplained (for example `tool_failed`, `internal_failure`, or a
helper that will not start), run `ControlKit report --json` from the repository and give the user
the archive path. Do not try to read or edit `~/Library/Logs/ControlKit` as an API.
