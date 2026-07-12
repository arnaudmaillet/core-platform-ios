---
name: verify
description: Build, install, and drive core-platform-ios in the iOS simulator to verify changes at the running app's surface.
---

# Verify core-platform-ios in the simulator

## Build + install

```bash
UDID=$(xcrun simctl list devices booted -j | jq -r '.devices[][0].udid')  # or boot one
xcodebuild build -project core-platform-ios.xcodeproj -scheme core-platform-ios \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath <scratch>/dd -skipMacroValidation
xcrun simctl install $UDID <scratch>/dd/Build/Products/Debug-iphonesimulator/core-platform-ios.app
```

`-skipMacroValidation` is required (SwiftProtobuf/Connect macros). Bundle id: `cn.wynn.core-platform-ios`.

## Drive

No tap injection available — use the DEBUG launch args (full list in the
auto-memory `app-feature-surface`). Always pass `-mock-auto-login` (mock mode).

```bash
xcrun simctl launch $UDID cn.wynn.core-platform-ios -mock-auto-login <args>
xcrun simctl io $UDID screenshot shot.png
```

Animations: the user's Simulator.app has Slow Animations ON. For real-speed
captures: `killall Simulator; simctl shutdown $UDID; simctl boot $UDID`
(headless — screenshots/video still work). `xcodebuild test` relaunches
Simulator.app and re-enables the slowdown.

Transitions: record + frame-extract, then bracket by brightness (map is
light ~87, feed is dark ~1-12):

```bash
xcrun simctl io $UDID recordVideo --codec h264 --force out.mp4 &  # kill -INT to stop
ffmpeg -i out.mp4 -vf "fps=4,scale=402:-2" frames/f%03d.png
for f in frames/*.png; do magick "$f" -colorspace Gray -format "%[fx:int(mean*100)] " info:; done
```

## Gotchas

- App on home screen after `simctl launch` printed a pid = it crashed at
  startup. Re-launch with `--console-pty ... > log 2>&1 &` to capture the
  fatal error (killing the pty kills the app — screenshot first).
- Video posts render black in sim captures (`AVPlayerLayer`); judge by
  chrome, or use a text page (mock: every index%3==2) via `-snap-start-index N`.
- `UITab` viewControllerProviders run eagerly at `tabs =` assignment —
  a crash there looks like "app never opened".
