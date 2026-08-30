#!/bin/zsh
# The hero transition's VISUAL harness: deterministic scripted flights on a
# HEADLESS simulator, recorded at full rate, judged frame by frame — the
# layer that catches what state assertions cannot ("logs pass while the
# screen is broken"), paired with the audit log so a green screen over a
# leaking pool cannot pass either.
#
# Usage:
#   Scripts/hero-qa/run.sh --all              # every case in cases.d/
#   Scripts/hero-qa/run.sh tapback-cycles     # one case by name
#   Scripts/hero-qa/run.sh --list
#
# Each case is a small zsh file in cases.d/ defining:
#   CASE_ARGS=(...)        launch arguments (the scripted choreography)
#   CASE_DURATION=28       seconds to record
#   CASE_CHECKS=(audit motion no-black settle-baseline)   which judges run
#   CASE_BASELINE_AT=6     when (s) the pre-flight baseline frame is taken,
#                          for the settle-baseline judge
#   CASE_LEAKS=1           optionally run `leaks` against the app afterwards
#
# Headless on purpose: no Simulator.app means no Slow Animations (the ×10
# multiplier that is invisible in-process), and recordVideo + screenshots
# work without a window. `xcodebuild test` would relaunch Simulator.app —
# this harness never calls it.
set -uo pipefail

cd "$(dirname "$0")/../.."
HERE="Scripts/hero-qa"
BUNDLE="cn.wynn.core-platform-ios"

# ---------------------------------------------------------------- selection --
CASES=()
case "${1:-}" in
  --list) ls "$HERE/cases.d" | sed 's/\.case$//'; exit 0 ;;
  --all|"") for f in "$HERE"/cases.d/*.case; do CASES+=("${${f:t}%.case}"); done ;;
  *) CASES=("$@") ;;
esac

OUT="hero-qa-out/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
echo "# Hero QA — $(date)\n" > "$SUMMARY"
FAILED=()

# --------------------------------------------------------------- simulator ---
UDID="$(xcrun simctl list devices booted -j | jq -r '.devices[][0].udid // empty' | head -1)"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl list devices available -j \
    | jq -r '[.devices[][] | select(.name | startswith("iPhone"))][0].udid')"
  xcrun simctl boot "$UDID"
fi
# Headless check is advisory: a visible Simulator.app with Slow Animations ON
# stretches every duration and the recordings become 10x films. Warn loudly.
if pgrep -xq Simulator; then
  SLOWMO="$(defaults read com.apple.iphonesimulator SlowMotionAnimation 2>/dev/null || echo 0)"
  echo "⚠️  Simulator.app is running (SlowMotionAnimation=$SLOWMO)." \
       "For honest timings: killall Simulator; simctl shutdown/boot, then rerun." | tee -a "$SUMMARY"
fi

# ------------------------------------------------------------------- build ---
DD="$OUT/dd"
echo "hero-qa: building…"
xcodebuild build -project core-platform-ios.xcodeproj -scheme core-platform-ios \
  -destination "platform=iOS Simulator,id=$UDID" -configuration Debug \
  -derivedDataPath "$DD" -skipMacroValidation CODE_SIGNING_ALLOWED=NO -quiet \
  || { echo "build failed" | tee -a "$SUMMARY"; exit 1; }
APP="$DD/Build/Products/Debug-iphonesimulator/core-platform-ios.app"
xcrun simctl install "$UDID" "$APP"
BUILD_STAMP=$(date +%s)

# ------------------------------------------------------------------ judges ---
# Frames are extracted at 30fps, 402px wide. All judges work on those.

judge_audit() { # $1=case dir — the audit log's own verdict, liveness first
  local dir="$1" log="$dir/hero-audit.log"
  [[ -s "$log" ]] || { echo "FAIL audit: sink missing or empty (the broken-harness case)"; return 1; }
  local mtime=$(stat -f %m "$log")
  (( mtime >= BUILD_STAMP )) || { echo "FAIL audit: log predates this build"; return 1; }
  local beats=$(grep -c "hero-audit\] beat" "$log")
  (( beats >= 1 )) || { echo "FAIL audit: no heartbeat — 0 checks is a broken harness, not a pass"; return 1; }
  if grep -q "hero-audit\] FAIL" "$log"; then
    echo "FAIL audit: $(grep "hero-audit\] FAIL" "$log" | head -3)"; return 1
  fi
  # The last settled census must be residue-free.
  local last=$(grep "state=settled" "$log" | tail -1)
  [[ -n "$last" ]] || { echo "FAIL audit: no settled sample"; return 1; }
  for field in animators interruptors retries cards stranded dupes; do
    local v=$(echo "$last" | sed -n "s/.*;$field=\([0-9-]*\).*/\1/p")
    [[ "$v" == "0" ]] || { echo "FAIL audit: $field=$v at final settle ($last)"; return 1; }
  done
  echo "ok audit ($beats beats, final: ${last#*hero;})"
}

judge_motion() { # $1=case dir — did anything visibly FLY?
  local dir="$1" prev="" best=0
  for f in "$dir"/frames/*.png; do
    if [[ -n "$prev" ]]; then
      local mae=$(magick compare -metric MAE "$prev" "$f" null: 2>&1 | sed 's/ .*//')
      local scaled=$(printf '%.0f' $(echo "$mae * 1000" | bc -l 2>/dev/null || echo 0))
      (( scaled > best )) && best=$scaled
    fi
    prev="$f"
  done
  (( best >= 15 )) || { echo "FAIL motion: max inter-frame MAE(x1000)=$best — nothing visibly moved"; return 1; }
  echo "ok motion (peak MAE x1000 = $best)"
}

judge_no_black() { # $1=case dir — no full-frame black dip mid-sequence
  local dir="$1" i=0 dips=0
  local -a means
  for f in "$dir"/frames/*.png; do
    means[$((++i))]=$(magick "$f" -colorspace Gray -format "%[fx:int(mean*100)]" info:)
  done
  for ((j=2; j<i; j++)); do
    if (( means[j] <= 2 && means[j-1] >= 15 && means[j+1] >= 15 )); then
      dips=$((dips+1))
      echo "  black dip at frame $j (${means[j-1]} -> ${means[j]} -> ${means[j+1]})"
    fi
  done
  (( dips == 0 )) || { echo "FAIL no-black: $dips single-frame black dips (the frame-0 flash family)"; return 1; }
  echo "ok no-black"
}

judge_settle_baseline() { # $1=case dir — the screen came BACK to what it was
  local dir="$1" base="$dir/baseline.png" last=$(ls "$dir"/frames/*.png | tail -1)
  [[ -f "$base" ]] || { echo "FAIL settle-baseline: no baseline captured"; return 1; }
  local final="$dir/final.png"
  magick "$last" -resize "$(magick identify -format '%wx%h' "$base")!" "$final"
  local mae=$(magick compare -metric MAE "$base" "$final" null: 2>&1 | sed 's/ .*//')
  local scaled=$(printf '%.0f' $(echo "$mae * 1000" | bc -l 2>/dev/null || echo 999))
  # Tolerant: clocks tick, covers animate. A stranded full-screen card or a
  # missing tile is two orders of magnitude past this.
  (( scaled <= 60 )) || { echo "FAIL settle-baseline: MAE(x1000)=$scaled vs pre-flight grid — something is stranded or missing"; return 1; }
  echo "ok settle-baseline (MAE x1000 = $scaled)"
}

# -------------------------------------------------------------------- runs ---
for CASE in "${CASES[@]}"; do
  spec="$HERE/cases.d/$CASE.case"
  [[ -f "$spec" ]] || { echo "unknown case: $CASE" | tee -a "$SUMMARY"; FAILED+=("$CASE"); continue; }
  CASE_ARGS=(); CASE_DURATION=30; CASE_CHECKS=(audit); CASE_BASELINE_AT=0; CASE_LEAKS=0
  source "$spec"
  dir="$OUT/$CASE"; mkdir -p "$dir/frames"
  echo "\n== $CASE (${CASE_DURATION}s) =="

  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl io "$UDID" recordVideo --codec h264 --force "$dir/run.mp4" &
  REC=$!
  # ⚠️ The recorder must ALWAYS be stopped — an orphaned recordVideo writes
  # until the disk is full (measured at 45GB once). Trap covers early exits.
  trap "kill -INT $REC 2>/dev/null" INT TERM

  xcrun simctl launch "$UDID" "$BUNDLE" \
    -mock-auto-login -hero-audit -zoom-live-log "${CASE_ARGS[@]}" >/dev/null

  if (( CASE_BASELINE_AT > 0 )); then
    sleep "$CASE_BASELINE_AT"
    xcrun simctl io "$UDID" screenshot "$dir/baseline.png" >/dev/null 2>&1
    sleep $(( CASE_DURATION - CASE_BASELINE_AT ))
  else
    sleep "$CASE_DURATION"
  fi
  xcrun simctl io "$UDID" screenshot "$dir/settled.png" >/dev/null 2>&1

  if (( CASE_LEAKS )); then
    PID=$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null \
      | awk -v b="UIKitApplication:$BUNDLE" '$3 ~ b {print $1}' | head -1)
    if [[ -n "$PID" && "$PID" != "-" ]]; then
      leaks "$PID" 2>/dev/null | grep -E "total leaked bytes|Zoom|FlightCard|VideoRender|SnapFeed" \
        > "$dir/leaks.txt" || true
      echo "  leaks: $(head -1 "$dir/leaks.txt" 2>/dev/null || echo 'unavailable')"
    fi
  fi

  # Collect the audit sink BEFORE terminating (Documents survives, but order
  # keeps the mtime honest), then stop everything.
  CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)
  [[ -n "$CONTAINER" ]] && cp "$CONTAINER/Documents/hero-audit.log" "$dir/" 2>/dev/null
  kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null; trap - INT TERM
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true

  ffmpeg -i "$dir/run.mp4" -vf "fps=30,scale=402:-2" "$dir/frames/f%04d.png" \
    -loglevel error 2>/dev/null
  frames=$(ls "$dir/frames" 2>/dev/null | wc -l | tr -d ' ')
  echo "  recorded $frames frames"

  # The judges, per the case's spec — every verdict lands in the summary.
  verdicts=()
  ok=1
  for check in "${CASE_CHECKS[@]}"; do
    case "$check" in
      audit)           v=$(judge_audit "$dir") || ok=0 ;;
      motion)          v=$(judge_motion "$dir") || ok=0 ;;
      no-black)        v=$(judge_no_black "$dir") || ok=0 ;;
      settle-baseline) v=$(judge_settle_baseline "$dir") || ok=0 ;;
      *) v="FAIL unknown check $check"; ok=0 ;;
    esac
    verdicts+=("$v"); echo "  $v"
  done

  # Evidence strip: eight frames across the run, one glance per case.
  sample=$(ls "$dir"/frames/*.png | awk "NR % $(( frames / 8 + 1 )) == 1" | head -8)
  [[ -n "$sample" ]] && magick montage ${=sample} -tile 8x1 -geometry +2+2 "$dir/strip.png" 2>/dev/null

  {
    echo "## $CASE — $([[ $ok == 1 ]] && echo PASS || echo '**FAIL**')"
    for v in "${verdicts[@]}"; do echo "- $v"; done
    echo "- evidence: \`$CASE/strip.png\` · \`$CASE/settled.png\` · \`$CASE/run.mp4\` · \`$CASE/hero-audit.log\`\n"
  } >> "$SUMMARY"
  (( ok )) || FAILED+=("$CASE")
done

echo "\n---\n$([[ ${#FAILED[@]} == 0 ]] && echo "All ${#CASES[@]} cases passed." \
  || echo "FAILED: ${FAILED[*]}")" >> "$SUMMARY"
echo "\nhero-qa: summary at $SUMMARY"
[[ ${#FAILED[@]} == 0 ]]
