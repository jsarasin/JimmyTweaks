#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "" && "${1:-}" != "--christmas" && "${1:-}" != "--fireplace-mask" ]]; then
    echo "Usage: Scripts/check-snow-storm.sh [--christmas|--fireplace-mask]" >&2; exit 2
fi
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ROOT="$PROJECT_ROOT/build/SnowStormCheck"
mkdir -p "$CHECK_ROOT"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$PROJECT_ROOT/Sources" -name '*.swift' ! -name main.swift -print0)
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$PROJECT_ROOT/build/ModuleCache" -parse-as-library -D TESTING \
    -framework AppKit -framework ImageIO -framework ApplicationServices -framework CoreGraphics \
    -framework CoreServices -framework ServiceManagement -framework Security -framework ScreenCaptureKit \
    "${SOURCES[@]}" "$PROJECT_ROOT/Tests/TestSupport.swift" "$PROJECT_ROOT/Tests/ChristmasTests.swift" "$PROJECT_ROOT/Tests/SnowStormFeatureCheck.swift" \
    -o "$CHECK_ROOT/SnowStormFeatureCheck"
if [[ "${1:-}" == "--christmas" ]]; then
    "$CHECK_ROOT/SnowStormFeatureCheck" --christmas "$CHECK_ROOT"
elif [[ "${1:-}" == "--fireplace-mask" ]]; then
    "$CHECK_ROOT/SnowStormFeatureCheck" --fireplace-mask
else
    "$CHECK_ROOT/SnowStormFeatureCheck" "$CHECK_ROOT"
fi
