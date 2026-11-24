#!/bin/zsh
# Runs one glyph's recipe with the shared tracer prepended (#2415, #2416, #2433,
# #2434, #2456–#2459). usage: run.sh <gen-name.swift> [args…]
# Swift runs top-level code from one file only, so the two are joined into a
# temporary main.swift and compiled.
set -e
here=${0:A:h}
recipe=${1:A}; shift
work=$(mktemp -d)
cat "$here/OwnerTrace.swift" "$recipe" > "$work/main.swift"
xcrun swiftc -O -o "$work/gen" "$work/main.swift" 2>&1 | grep -v "warning:" | grep -v "^ *|" | grep -v "^\s*$" || true
"$work/gen" "$@"
rm -rf "$work"
