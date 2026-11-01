#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DEVELOPER_ID_APPLICATION:?Set the Developer ID Application signing identity}"
: "${BUNDLE_IDENTIFIER:?Set your stable owned reverse-DNS bundle identifier}"
: "${NOTARY_PROFILE:?Set an existing notarytool keychain-profile name}"
if [[ "$BUNDLE_IDENTIFIER" == local.* ]]; then echo "Use an owned distribution bundle identifier." >&2; exit 2; fi
"$PROJECT_ROOT/Scripts/build.sh" Release
DIST_ROOT="${DIST_ROOT:-$PROJECT_ROOT/dist}"
mkdir -p "$DIST_ROOT"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/jimmy-tweaks-distribution.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Jimmy Tweaks.app"
ditto "${BUILD_ROOT:-$PROJECT_ROOT/build}/Release/Jimmy Tweaks.app" "$APP"
xattr -cr "$APP"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$APP/Contents/Helpers/IconAbsorberAgent"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp \
    --entitlements "$PROJECT_ROOT/Resources/JimmyTweaks.entitlements" "$APP"
codesign --verify --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$STAGING/Jimmy-Tweaks-notarization.zip"
xcrun notarytool submit "$STAGING/Jimmy-Tweaks-notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
mkdir -p "$STAGING/image"
ditto "$APP" "$STAGING/image/Jimmy Tweaks.app"
ln -s /Applications "$STAGING/image/Applications"
cp "$PROJECT_ROOT/INSTALL.txt" "$STAGING/image/INSTALL.txt"
DMG="$DIST_ROOT/Jimmy-Tweaks-1.0.dmg"
hdiutil create -volname "Jimmy Tweaks" -srcfolder "$STAGING/image" -format UDZO -ov "$DMG"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Signed, notarized distribution: $DMG"
