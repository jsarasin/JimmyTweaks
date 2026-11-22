#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ROOT="$PROJECT_ROOT/build/RequestsCheck"
mkdir -p "$CHECK_ROOT"
RUN_ROOT="$(mktemp -d "$CHECK_ROOT/Run.XXXXXX")"
printf '%s\n' "$RUN_ROOT" > "$CHECK_ROOT/latest-run.txt"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$PROJECT_ROOT/Sources" -name '*.swift' ! -name main.swift -print0)
xcrun swiftc -swift-version 5 -target arm64-apple-macosx27.0 -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path "$PROJECT_ROOT/build/ModuleCache" -parse-as-library -D TESTING \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreServices \
    -framework ServiceManagement -framework Security -framework ScreenCaptureKit \
    "${SOURCES[@]}" "$PROJECT_ROOT/Tests/TestSupport.swift" "$PROJECT_ROOT/Tests/RequestTests.swift" \
    "$PROJECT_ROOT/Tests/RequestsFeatureCheck.swift" -o "$CHECK_ROOT/RequestsFeatureCheck"
"$CHECK_ROOT/RequestsFeatureCheck" "$RUN_ROOT"
