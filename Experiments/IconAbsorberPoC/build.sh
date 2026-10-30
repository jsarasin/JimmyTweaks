#!/bin/bash
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$PROBE_ROOT/build"
APP="$OUT/Icon Absorber Probe.app"
mkdir -p "$APP/Contents/MacOS" "$OUT/ModuleCache"
SDK="$(xcrun --show-sdk-path)"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -isysroot "$SDK" -target arm64-apple-macos27.0 \
    -Wall -Wextra -Werror -c "$PROBE_ROOT/AssessmentAdapter.m" -o "$OUT/AssessmentAdapter.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$SDK" \
    -module-cache-path "$OUT/ModuleCache" -import-objc-header "$PROBE_ROOT/AssessmentAdapter.h" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics \
    "$PROBE_ROOT/main.swift" "$OUT/AssessmentAdapter.o" -o "$APP/Contents/MacOS/IconAbsorberProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.jimmytweaks.iconabsorber.probe</string>
<key>CFBundleExecutable</key><string>IconAbsorberProbe</string>
<key>CFBundleName</key><string>Icon Absorber Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --options runtime "$APP"
printf '%s\n' "$APP"
