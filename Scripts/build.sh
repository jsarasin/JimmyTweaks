#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Development}"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build}"
APP_BUNDLE="$BUILD_ROOT/$CONFIGURATION/Jimmy Tweaks.app"
BUNDLE_ID="${BUNDLE_IDENTIFIER:-local.jimmytweaks.app}"
if [[ "$CONFIGURATION" != "Development" && "$CONFIGURATION" != "Release" ]]; then
    echo "Usage: Scripts/build.sh [Development|Release]" >&2; exit 2
fi
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]]; then echo "Invalid bundle identifier." >&2; exit 2; fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$BUILD_ROOT/ModuleCache"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$PROJECT_ROOT/Sources" -name '*.swift' -print0)
FLAGS=(-Onone -g)
if [[ "$CONFIGURATION" == "Release" ]]; then FLAGS=(-O -D RELEASE); fi
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$BUILD_ROOT/ModuleCache" -module-name JimmyTweaks \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreServices \
    -framework ServiceManagement -framework Security -framework ScreenCaptureKit "${FLAGS[@]}" "${SOURCES[@]}" \
    -o "$APP_BUNDLE/Contents/MacOS/JimmyTweaks"
bash "$PROJECT_ROOT/Scripts/build-icon-absorber-agent.sh" "$APP_BUNDLE/Contents/Helpers"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
xcrun swift -module-cache-path "$BUILD_ROOT/ModuleCache" "$PROJECT_ROOT/Scripts/make-icon.swift" "$BUILD_ROOT/AppIcon.iconset"
cp "$BUILD_ROOT/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/Resources/PermissionGuidePortrait.png" "$APP_BUNDLE/Contents/Resources/PermissionGuidePortrait.png"
xattr -cr "$APP_BUNDLE"
codesign --force --sign - --options runtime --entitlements "$PROJECT_ROOT/Resources/JimmyTweaks.entitlements" "$APP_BUNDLE"
echo "$APP_BUNDLE"
