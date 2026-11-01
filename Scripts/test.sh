#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="${TEST_ROOT:-$PROJECT_ROOT/build/Tests}"
mkdir -p "$TEST_ROOT/ModuleCache"
RUN_ROOT="$(mktemp -d "$TEST_ROOT/Run.XXXXXX")"
printf '%s\n' "$RUN_ROOT" > "$TEST_ROOT/latest-run.txt"
COMMON=(-swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" -module-cache-path "$TEST_ROOT/ModuleCache" -parse-as-library)
CORE=()
while IFS= read -r -d '' file; do CORE+=("$file"); done < <(find "$PROJECT_ROOT/Sources/Core" -name '*.swift' -print0)
xcrun swiftc "${COMMON[@]}" "${CORE[@]}" "$PROJECT_ROOT/Tests/TestSupport.swift" "$PROJECT_ROOT/Tests/CoreTests.swift" -o "$TEST_ROOT/CoreTests"
"$TEST_ROOT/CoreTests" "$RUN_ROOT/logging-scratch"
python3 "$PROJECT_ROOT/Tests/check_boundaries.py"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$PROJECT_ROOT/Sources" -name '*.swift' ! -name main.swift -print0)
xcrun swiftc "${COMMON[@]}" -D TESTING -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreServices \
    -framework ServiceManagement -framework Security -framework ScreenCaptureKit "${SOURCES[@]}" "$PROJECT_ROOT/Tests/TestSupport.swift" "$PROJECT_ROOT/Tests/EngineTests.swift" "$PROJECT_ROOT/Tests/PermissionTests.swift" "$PROJECT_ROOT/Tests/ShortcutTests.swift" "$PROJECT_ROOT/Tests/SettingsRegressionTests.swift" "$PROJECT_ROOT/Tests/IconAbsorberPreviewTests.swift" "$PROJECT_ROOT/Tests/UISmoke.swift" -o "$TEST_ROOT/UISmoke"
"$TEST_ROOT/UISmoke" "$RUN_ROOT/UI"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" -module-cache-path "$TEST_ROOT/ModuleCache" \
    -framework AppKit "$PROJECT_ROOT/Tests/Fixtures/WindowFixture.swift" -o "$TEST_ROOT/WindowFixture"
