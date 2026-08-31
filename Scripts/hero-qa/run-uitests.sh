#!/bin/zsh
# Runs the Hero* XCUITest suites with the simulator etiquette they need.
#
# Why the wrapper exists: `xcodebuild test` relaunches Simulator.app, and the
# user's Simulator keeps Slow Animations ON deliberately — which silently
# multiplies every animation duration ~10x and is undetectable in-process
# (layer.speed reads 1.0 either way). The suites are seq-gated, not
# sleep-timed, so they'd still pass — slowly; the wrapper flips the default
# off for the run and RESTORES the user's setting on every exit path.
#
# Usage:
#   Scripts/hero-qa/run-uitests.sh                    # every Hero* suite
#   Scripts/hero-qa/run-uitests.sh HeroMatrixUITests  # one suite
set -euo pipefail

cd "$(dirname "$0")/../.."

SUITE="${1:-}"
ONLY=(-only-testing:core-platform-iosUITests)
if [[ -n "$SUITE" ]]; then
  ONLY=(-only-testing:"core-platform-iosUITests/$SUITE")
fi

# --- Slow Animations etiquette -----------------------------------------------
SLOWMO_KEY=SlowMotionAnimation
SLOWMO_SAVED="$(defaults read com.apple.iphonesimulator "$SLOWMO_KEY" 2>/dev/null || echo "unset")"
restore_slowmo() {
  if [[ "$SLOWMO_SAVED" == "unset" ]]; then
    defaults delete com.apple.iphonesimulator "$SLOWMO_KEY" 2>/dev/null || true
  else
    defaults write com.apple.iphonesimulator "$SLOWMO_KEY" "$SLOWMO_SAVED"
  fi
}
trap restore_slowmo EXIT
defaults write com.apple.iphonesimulator "$SLOWMO_KEY" -bool NO

# --- Destination -------------------------------------------------------------
UDID="$(xcrun simctl list devices booted -j | jq -r '.devices[][0].udid // empty' | head -1)"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl list devices available -j \
    | jq -r '[.devices[][] | select(.name | startswith("iPhone"))][0].udid')"
fi
[[ -n "$UDID" ]] || { echo "no iPhone simulator available" >&2; exit 1; }
echo "hero-qa: running UI tests on $UDID (SlowMotionAnimation forced off; was: $SLOWMO_SAVED)"

# --- Run ---------------------------------------------------------------------
OUT="hero-qa-out/uitests-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
xcodebuild test \
  -project core-platform-ios.xcodeproj \
  -scheme core-platform-ios \
  -destination "platform=iOS Simulator,id=$UDID" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$OUT/results.xcresult" \
  "${ONLY[@]}"
echo "hero-qa: result bundle (screenshots inside): $OUT/results.xcresult"
