#!/usr/bin/env bash
# Regenerates Packages/Kit/CoreContracts from buf.build/core-platform/contracts.
#
#   Scripts/generate-contracts.sh              regenerate from the pinned commit
#   Scripts/generate-contracts.sh <label|ref>  resolve ref, update the pin, regenerate
#   Scripts/generate-contracts.sh --check      regenerate from pin and fail on drift (CI)
set -euo pipefail
cd "$(dirname "$0")/.."

MODULE="buf.build/core-platform/contracts"
PIN_FILE=".contracts-pin"
CHECK=false

REF="${1:-}"
if [[ "$REF" == "--check" ]]; then
  CHECK=true
  REF=""
fi

if [[ -n "$REF" ]]; then
  COMMIT=$(buf registry module label info "$MODULE:$REF" --format json | sed -n 's/.*"commit":"\([a-f0-9]*\)".*/\1/p')
  if [[ -z "$COMMIT" ]]; then
    COMMIT="$REF" # assume the ref is already a commit
  fi
  echo "$COMMIT" > "$PIN_FILE"
  echo "Pinned $MODULE to commit $COMMIT (from '$REF')"
fi

COMMIT=$(cat "$PIN_FILE")
buf generate "$MODULE:$COMMIT" --template buf.gen.yaml

if $CHECK && ! git diff --exit-code --quiet -- Packages/Kit/CoreContracts; then
  echo "error: generated contracts are out of sync with pin $COMMIT — run Scripts/generate-contracts.sh and commit" >&2
  exit 1
fi
