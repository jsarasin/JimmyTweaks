#!/bin/bash
# One focused final feature check, deliberately independent of the full test suite.
set -euo pipefail
if [[ "${1:-}" != "" && "${1:-}" != "--build-only" ]]; then
    echo "Usage: Scripts/check-effects.sh [--build-only]" >&2; exit 2
fi
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EFFECT_ROOT="$PROJECT_ROOT/build/EffectsCheck"
mkdir -p "$EFFECT_ROOT"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$PROJECT_ROOT/Sources" -name '*.swift' ! -name main.swift -print0)
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$PROJECT_ROOT/build/ModuleCache" -parse-as-library -D TESTING \
    -framework AppKit -framework MetalKit -framework ApplicationServices -framework CoreGraphics \
    -framework CoreServices -framework ServiceManagement -framework Security -framework ScreenCaptureKit \
    "${SOURCES[@]}" "$PROJECT_ROOT/Tests/TestSupport.swift" "$PROJECT_ROOT/Tests/EffectsFeatureCheck.swift" \
    -o "$EFFECT_ROOT/EffectsFeatureCheck"
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
"$EFFECT_ROOT/EffectsFeatureCheck" "$EFFECT_ROOT"
codesign --verify --strict "$PROJECT_ROOT/build/Development/Jimmy Tweaks.app"
git -C "$PROJECT_ROOT" diff --check
