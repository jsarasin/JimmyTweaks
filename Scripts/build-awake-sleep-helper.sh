#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTENTS="${1:?Supply the app Contents directory}"
POWER_BUNDLE_ID="${BUNDLE_IDENTIFIER:-${PRODUCT_BUNDLE_IDENTIFIER:-local.jimmytweaks.app}}"
if [[ ! "$POWER_BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]]; then echo "Invalid power-helper bundle identifier." >&2; exit 2; fi
POWER_SERVICE="$POWER_BUNDLE_ID.power-helper"
POWER_CACHE="${DERIVED_FILE_DIR:-$PROJECT_ROOT/build/AwakeSleepHelper}/ModuleCache"
mkdir -p "$CONTENTS/Library/HelperTools" "$CONTENTS/Library/LaunchDaemons" "$POWER_CACHE"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$POWER_CACHE" -O -framework Foundation -framework Security -framework SystemConfiguration \
    "$PROJECT_ROOT/Sources/Core/AwakeSleep.swift" "$PROJECT_ROOT/Sources/AwakeSleep/PowerHelperProtocol.swift" \
    "$PROJECT_ROOT/Sources/AwakeSleep/PowerHelperSupport.swift" \
    "$PROJECT_ROOT/Helpers/AwakeSleepHelper/main.swift" -o "$CONTENTS/Library/HelperTools/AwakeSleepHelper"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --identifier "$POWER_SERVICE" --options runtime "$CONTENTS/Library/HelperTools/AwakeSleepHelper"
cat > "$CONTENTS/Library/LaunchDaemons/AwakeSleepHelper.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$POWER_SERVICE</string>
<key>BundleProgram</key><string>Contents/Library/HelperTools/AwakeSleepHelper</string>
<key>MachServices</key><dict><key>$POWER_SERVICE</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ProcessType</key><string>Background</string>
<key>AssociatedBundleIdentifiers</key><array><string>$POWER_BUNDLE_ID</string></array>
</dict></plist>
EOF
