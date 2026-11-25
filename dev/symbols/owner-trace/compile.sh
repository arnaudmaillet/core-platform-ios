#!/bin/zsh
# Compiles a symbol catalogue into <out>/c.bundle with actool, for the
# renderers and the size check. usage: compile.sh <Symbols.xcassets> <out dir>
set -e
cat=${1:A}; out=${2:A}
rm -rf "$out/c.bundle"; mkdir -p "$out/c.bundle/Contents/Resources"
xcrun actool --compile "$out/c.bundle/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$out/partial.plist" --errors --warnings --notices --output-format human-readable-text "$cat" | grep -v "^/\* com.apple.actool.compilation-results \*/" | grep -v "c.bundle/Contents/Resources/Assets.car" || true
test -f "$out/c.bundle/Contents/Resources/Assets.car"
cat > "$out/c.bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.symbols.preview</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
