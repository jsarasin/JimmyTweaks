#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$PROJECT_ROOT/build/IconAbsorberTests"
mkdir -p "$TEST_ROOT/ModuleCache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$TEST_ROOT/ModuleCache" -parse-as-library \
    -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit \
    "$PROJECT_ROOT/Sources/Core/Preferences.swift" "$PROJECT_ROOT/Sources/Core/Geometry.swift" "$PROJECT_ROOT/Sources/Core/IconAbsorberSelection.swift" \
    "$PROJECT_ROOT/Sources/Core/FileLogger.swift" "$PROJECT_ROOT/Sources/App/Permissions.swift" \
    "$PROJECT_ROOT/Sources/IconAbsorber/AssertionClient.swift" "$PROJECT_ROOT/Sources/IconAbsorber/StatusItems.swift" \
    "$PROJECT_ROOT/Sources/IconAbsorber/StatusItemPictures.swift" "$PROJECT_ROOT/Sources/IconAbsorber/IconAbsorberController.swift" \
    "$PROJECT_ROOT/Tests/TestSupport.swift" "$PROJECT_ROOT/Tests/IconAbsorberTests.swift" -o "$TEST_ROOT/IconAbsorberTests"
"$TEST_ROOT/IconAbsorberTests" "$TEST_ROOT/logs"
bash "$PROJECT_ROOT/Scripts/build-icon-absorber-agent.sh" "$TEST_ROOT/Helpers"
xcrun swiftc -swift-version 5 -D TESTING -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$TEST_ROOT/ModuleCache" -parse-as-library -framework AppKit \
    "$PROJECT_ROOT/Sources/IconAbsorber/AssertionClient.swift" "$PROJECT_ROOT/Tests/IconAbsorberClientTests.swift" -o "$TEST_ROOT/IconAbsorberClientTests"
"$TEST_ROOT/IconAbsorberClientTests" "$TEST_ROOT/Helpers/IconAbsorberAgent"
