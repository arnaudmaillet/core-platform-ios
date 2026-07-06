#!/usr/bin/env bash
# Runs formatting and lint checks; CI calls this, and so should you before pushing.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v swiftformat >/dev/null; then
  swiftformat --lint .
else
  echo "warning: swiftformat not installed (brew install swiftformat)" >&2
fi

if command -v swiftlint >/dev/null; then
  swiftlint --strict
else
  echo "warning: swiftlint not installed (brew install swiftlint)" >&2
fi
