# Milestone 4 — repository discovery

Status: implemented and ready for review. Milestones 5–6 have not started.

## Delivered

- `ControlKitDiscovery`, a synchronous, read-only library depending only on Foundation/Darwin and
  `ControlKitCore`. It has no process execution, configuration writes, transport, or simulator access.
- Canonical `buildServer.json`, optional `controlkit.json` profiles, explicit overrides, per-field
  provenance, and bounded filesystem container discovery.
- Explicit errors for stale selected paths, invalid configuration, resource limits, and I/O.
  Missing choices and ambiguity retain a report with available profiles/candidates.
- Experimental `ControlKit probe discover`, nested help, `just probe-discover`, and `discovery-check`.
  The test-only reference model remains outside the executable dependency graph.

## Resolution rules

Precedence is **explicit options → selected profile → recognized build-server metadata →
unambiguous filesystem container**. Workspace/project is one selection, not two separately merged
fields. A workspace and project in the same selected layer is an error. Scheme and configuration
resolve independently. Each chosen field reports its source and, where applicable, config file
and profile name.

1. `--project DIR` establishes an explicit root; only that directory supplies configuration files.
   Without it, walk up from the current directory to the nearest `.git` directory or worktree file.
   Within that boundary, use the nearest canonical config file of each kind independently.
   Without a Git marker, use the original working directory only, not unrelated ancestor metadata.
2. Match `buildServer.json` using actual directory-entry spelling, even on case-insensitive volumes.
   There is no lowercase alias. Configuration files must be regular files, not symlinks or FIFOs.
3. Relative configuration paths belong to the config file's directory. Relative explicit paths belong
   to the resolved root. Selected containers must remain inside that root; an absolute build-server
   path into another checkout is stale, not a reason to build the other checkout.
4. The initial root may resolve a symlink alias. Discovered symlinks are never traversed, and selected
   container path components and package markers may not be symlinks. Projects require a regular
   `project.pbxproj`; workspaces require a regular `contents.xcworkspacedata`. Contents are not parsed.
5. Syntax/type/schema errors in a present configuration fail even with overrides. A well-formed but
   stale lower-priority container can be repaired by an explicit override. Never silently fall back
   from a stale winning path.
6. Without a selected container, traverse iteratively in sorted order. One candidate may be selected;
   multiple candidates require an explicit choice. Workspaces get no preference over projects.
   Packages are terminal: an embedded workspace is not a second candidate.
7. Traversal excludes dot-prefixed directories and `DerivedData`, `Pods`, `Carthage`, `node_modules`.
   Excluded entries still consume the entry budget. Explicit paths can select an excluded directory.
   Encountering an otherwise eligible directory beyond depth 4 fails rather than declaring a partial
   search unambiguous.

These are filesystem observations, not a lock against another process editing the repository.
Later build execution must revalidate its inputs; this is not an adversarial same-user sandbox.

## Recognized build-server metadata

The adapter recognizes `"name": "xcode build server"` plus `"kind": "xcode"`, then reads only
`workspace` and optional `scheme`. Other providers/modes produce an `unsupported_build_server`
finding and supply no settings. `argv` is never executed. `build_root` is an indexing-cache location,
not ControlKit's build directory, and is ignored. Unknown payload fields are not copied into reports.

Research reference: SolaWing/xcode-build-server at
[`438d0ae21778af955d7025d2013ebd419d161427`](https://github.com/SolaWing/xcode-build-server/tree/438d0ae21778af955d7025d2013ebd419d161427),
particularly `config/config.py`, `config/cmd.py`, and `Readme.md`. This is the inspected adapter
shape, not a claim of general BSP compatibility.

Two upstream details matter:

- A project can be recorded as `App.xcodeproj/project.xcworkspace` even when that workspace does not
  exist. The adapter normalizes only the absent fallback to its enclosing project; a real embedded
  workspace with regular `contents.xcworkspacedata` remains a workspace.
- Scheme may be omitted to bind the indexer to the latest-built scheme. ControlKit does **not** copy that
  nondeterminism: it reports a missing scheme. A kind=xcode config can omit workspace as well.

No architectural change was needed. Scheme/configuration discovery and validation must wait for
milestone 5's bounded Apple-tool runner; the milestone-4 success label is `filesystem_only`.

## Additional shared settings

For a repository whose build server already supplies workspace/project and scheme:

```json
{
  "schemaVersion": 1,
  "defaultProfile": "backend",
  "profiles": {
    "backend": {
      "configuration": "Debug"
    }
  }
}
```

Profile fields currently supported: `workspace`, `xcodeProject`, `scheme`, `configuration`.
Unknown ControlKit fields are errors, not silently ignored typos. `schemaVersion` and `profiles` are
required; `defaultProfile` is optional. `--profile` overrides the default. Nonempty profiles without
a selection require a choice, even with only one profile. An unknown requested/default profile is
an error. No machine-local device state, credentials, or toolchain/build cache paths belong here.

Both configuration formats reject duplicate object keys, including escaped spellings, before
Foundation decoding. Errors do not echo raw JSON or decoder descriptions.

## Bounds and failure semantics

| Owned work | Enforced bound |
| --- | --- |
| Ancestor checks | 32 directories including the starting directory |
| Listed entries | 1,024 total across config lookup and traversal; cached listings counted once |
| Traversal depth | Root at 0, candidate containers at most 4 edges below it |
| Each configuration file | 64 KiB, maximum JSON nesting 32 |
| Profiles | 16; names 1–128 UTF-8 bytes |
| Selected setting text | 1–4,096 UTF-8 bytes; no control characters |
| Discovery deadline | Default 5 s, minimum 1 ms, maximum 30 s |

Known regular files are opened without following a final symlink and rechecked with `fstat`.
Reads are chunked with a limit-plus-one guard against growth. The total traversal queue, directory
cache, and candidate list are bounded by the entry limit. Traversal is not recursive.

Deadline checks are cooperative between OS calls. **A blocked filesystem syscall cannot be
interrupted by this implementation.** No network-filesystem hard timeout or adversarial concurrent
filesystem-mutation guarantee was measured. Foundation allocations are not an owned-memory quota.

The experimental command always emits one JSON result for resolver success/failure; incomplete
choices and failures exit 1. Argument Parser still owns syntax errors and help. This is **not** the
approved production envelope/exit-code contract. No production `doctor`/`setup` command is claimed.

## Verification performed

On macOS 26.7 / Apple silicon:

- `DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer just check` — passed, build `27A266a`.
- `DEVELOPER_DIR=/Applications/Xcode-26.4.1.app/Contents/Developer just check` — passed, build `17E202`.
- Both runs include source/package-boundary audit, strict format checks, warnings-as-errors debug
  and release tests/builds, install/PATH tests in temporary homes, nested help, CLI discovery
  workflow, and the existing simulator fixture/helper build.
- 59 test functions total, including 23 new discovery tests. Existing deterministic model tests
  still run 1,280 scenarios per default test invocation.
- New tests cover source precedence/provenance, canonical spelling, embedded workspaces, nearest
  config ownership, Git/worktree boundaries, missing profiles/settings, stale paths and overrides,
  ambiguity, symlinks, FIFOs, JSON errors/redaction, duplicate keys, and exact entry/depth/ancestor/
  file-size/nesting/profile limits. Deadline tests use an injected clock, not wall-clock sleeps.
- CLI checks assert JSON and exit status against temporary repositories and the real checked-in
  `Probe/ControlKitProbe.xcodeproj`. They do not run that project or assert that arbitrary schemes work.

Xcode 26.4.1 emitted `DVTDeviceOperation` diagnostics about an empty device build number during the
successful helper build. Swift compiler warnings remain errors. No simulator was booted or erased,
global Xcode selection was not changed, and real shell profiles were not edited by these checks.

No fresh live XCTest smoke, real external app build, iOS 27 runtime, blocked network filesystem, or
production concurrency/performance qualification was performed in this milestone.

## Try it

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
just cli help probe discover
just probe-discover --project . --scheme ControlKitProbe --configuration Debug
just discovery-check
just probe-discover --project /path/to/repo --profile backend
```

Pause for review here. Next is the bounded process/simulator layer, then helper lifecycle/transport,
with separate review checkpoints. Guided setup and project build orchestration remain later work.
