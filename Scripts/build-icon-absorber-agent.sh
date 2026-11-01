#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:?Supply the app Contents/Helpers directory}"
AGENT_CACHE="${DERIVED_FILE_DIR:-$PROJECT_ROOT/build/IconAbsorberAgent}/ModuleCache"
mkdir -p "$OUTPUT" "$AGENT_CACHE"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$AGENT_CACHE" \
    -target arm64-apple-macos27.0 -isysroot "$(xcrun --show-sdk-path)" -Wall -Wextra \
    -framework AppKit -framework Foundation \
    "$PROJECT_ROOT/Helpers/IconAbsorberAgent/AssessmentAdapter.m" "$PROJECT_ROOT/Helpers/IconAbsorberAgent/main.m" \
    -o "$OUTPUT/IconAbsorberAgent"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$OUTPUT/IconAbsorberAgent"
