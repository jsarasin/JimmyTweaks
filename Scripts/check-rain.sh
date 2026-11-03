#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ROOT="$PROJECT_ROOT/build/RainCheck"
mkdir -p "$CHECK_ROOT"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$PROJECT_ROOT/Sources" -name '*.swift' ! -name main.swift -print0)
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$PROJECT_ROOT/build/ModuleCache" -parse-as-library -D TESTING \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreServices \
    -framework ServiceManagement -framework Security -framework ScreenCaptureKit \
    "${SOURCES[@]}" "$PROJECT_ROOT/Tests/TestSupport.swift" "$PROJECT_ROOT/Tests/RainFeatureCheck.swift" \
    -o "$CHECK_ROOT/RainFeatureCheck"
"$CHECK_ROOT/RainFeatureCheck" "$CHECK_ROOT"
