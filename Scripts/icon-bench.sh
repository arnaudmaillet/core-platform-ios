#!/usr/bin/env bash
#
# Runs the animated-icon instrument (`-icon-bench`) across a matrix of
# configurations and prints one machine-readable line per run.
#
#   Scripts/icon-bench.sh                          # default matrix, iPhone 17 Pro Max
#   Scripts/icon-bench.sh "iPhone SE (3rd generation)"
#   Scripts/icon-bench.sh "iPhone 17 Pro Max" 10   # 10s measurement window
#
# ⚠️ THE SIMULATOR ANSWERS ONLY HALF THE QUESTION, and it is the less
# interesting half. Memory, CPU, cold-dress time and "does it look right" are
# real here. FRAME COST IS NOT: the simulator does not model tile-based deferred
# rendering, so the offscreen passes that dominate on hardware are nearly free —
# which is exactly how an unshippable design passes a simulator run. Take the
# frame numbers from a DEVICE, with Instruments (Core Animation + GPU + Energy).
#
# ⚠️ Simulator > Slow Animations multiplies every duration by 10 and is
# invisible from inside the process. This script boots headless (no
# Simulator.app) partly to keep that off.
set -euo pipefail

DEVICE="${1:-iPhone 17 Pro Max}"
WINDOW="${2:-6}"
BUNDLE_ID="cn.wynn.core-platform-ios"
SCHEME="core-platform-ios"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "▸ building…"
BUILD_DIR=$(xcodebuild -project "$ROOT/core-platform-ios.xcodeproj" -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$DEVICE" -skipMacroValidation \
  -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')
xcodebuild -project "$ROOT/core-platform-ios.xcodeproj" -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$DEVICE" -skipMacroValidation \
  -configuration Debug build > /dev/null

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" > /dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$BUILD_DIR/$SCHEME.app"

# Each row is a set of extra flags. The default (first row) is the recommended
# design; every other row disables exactly ONE thing, so a difference is
# attributable to that thing and nothing else.
MATRIX=(
  ""                                              # recommended: still + track, quantised, 30fps, shadowPath, baked mask, shared
  #
  # THE HEADLINE PAIR. Read `projected128_mb` on these two lines and nothing
  # else, if you read nothing else: 9.0 against 216.8. Same picture (verified at
  # 0.51/255 worst by -icon-bench-verify), 24x the memory.
  "-icon-bench-wire still -icon-bench-variety all"
  "-icon-bench-wire sheet -icon-bench-variety all"
  # What 60fps costs on each representation. On a sheet it is bytes; on a track
  # it is nothing at all.
  "-icon-bench-wire still -icon-bench-fps 60 -icon-bench-max-frames 60"
  "-icon-bench-wire sheet -icon-bench-fps 60 -icon-bench-max-frames 60"
  # Real interpolation: 60 presented fps at the same memory as 12.
  "-icon-bench-sampling continuous -icon-bench-variety all"
  #
  "-icon-bench-clock free"                        # the staggered-beginTime version
  "-icon-bench-shadow none"                       # the pathless shadow shipping today
  "-icon-bench-mask clip"                         # the card mask a pre-rounded asset removes
  "-icon-bench-texture distinct"                  # the shared-texture assumption, inverted
  "-icon-bench-variety 1"                         # maximal sharing
  "-icon-bench-wire realGIF"                      # per-pixel artwork: cannot decompose, falls back to sheets
  "-icon-bench-ground plain"                      # how much of the cost is MapKit's
  "-icon-bench-pan"                               # the recycling storm
)

echo "▸ device: $DEVICE   window: ${WINDOW}s   runs: ${#MATRIX[@]}"
echo

for extra in "${MATRIX[@]}"; do
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
  # shellcheck disable=SC2086
  xcrun simctl launch --console-pty "$DEVICE" "$BUNDLE_ID" \
    -icon-bench -icon-bench-report "$WINDOW" -icon-bench-exit $extra 2>/dev/null \
    | grep --line-buffered "^ICONBENCH" || echo "ICONBENCH FAILED (${extra:-default})"
done

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
echo
echo "▸ correctness check (decomposition against the sheet, pixel by pixel):"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch --console-pty "$DEVICE" "$BUNDLE_ID" \
  -icon-bench -icon-bench-verify -icon-bench-latency 0 2>/dev/null \
  | grep --line-buffered -m 1 "^ICONBENCH-VERIFY worst" || echo "VERIFY FAILED"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true

echo
echo "▸ done. Frame numbers above are SIMULATOR numbers — see the header."
