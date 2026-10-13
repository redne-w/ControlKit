#!/bin/bash
# Local compiler-backed auditing, not a production subprocess supervisor.
set -euo pipefail
if [ "${1:-}" = "--help" ]; then
    printf 'Usage: bash Tools/check-source.sh\nChecks Swift source sizes and package boundaries.\n'
    exit 0
fi
[ "$#" -eq 0 ] || { printf 'Unexpected arguments; see --help.\n' >&2; exit 2; }
mkdir -p .build
runtime=$(mktemp -d "$PWD/.build/source-check.XXXXXX")
trap 'rm -rf "$runtime"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -warnings-as-errors Tools/SourceCheck.swift -o "$runtime/check"
"$runtime/check" self-test
# Exercise the selected compiler too: a renamed AST node must not silently bypass the line rule.
awk 'BEGIN { print "func fixture() {"; for (i=0; i<69; i++) print "    // body"; print "}" }' \
    > "$runtime/oversized.swift"
xcrun swiftc -frontend -dump-parse "$runtime/oversized.swift" > "$runtime/fixture.ast"
if "$runtime/check" functions fixture "$runtime/fixture.ast" 2> "$runtime/expected-error"; then
    printf 'Compiler/checker compatibility test failed: accepted a 71-line function.\n' >&2
    exit 1
fi
xcrun swift package dump-package | "$runtime/check" package -
printf '%s\n' Package.swift > "$runtime/files"
find Sources Tests Probe/Helper Probe/Fixture Helper Tools Specification \
    -type f -name '*.swift' >> "$runtime/files"
awk 'END { if (NR > 256) exit 1 }' "$runtime/files"
while IFS= read -r file; do
    "$runtime/check" source "$file"
    # Swift 6.2 -dump-parse reports a spurious type error for closure default arguments but still
    # prints the full tree, so its exit status is ignored; the checker rejects missing or
    # malformed output. Limit parser CPU; external build-tool wall time is not guaranteed.
    (ulimit -t 30; xcrun swiftc -frontend -dump-parse "$file" 2>/dev/null || true) \
        | "$runtime/check" functions "$file" -
done < "$runtime/files"
printf 'Source limits and package boundaries passed.\n'
