from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
for name in ["Sources/Core/ScriptsPreview.swift", "Sources/Settings/ScriptsPage.swift"]:
    text = (root / name).read_text()
    forbidden = [r"\bProcess\s*\(", r"\bURLSession\b", r"\bTimer\b", r"\bDispatchSource", r"\bNSAppleScript\b", r"\bNSScriptCommand\b", r"\bNSWorkspace\b", r"\bURLRequest\b"]
    for pattern in forbidden:
        assert not re.search(pattern, text), (name, pattern)
all_sources = "\n".join(path.read_text() for path in (root / "Sources").rglob("*.swift"))
assert "import SwiftUI" not in all_sources
assert "AXRaise" not in all_sources
assert "CGWarpMouseCursorPosition" not in all_sources
assert "URLSession" not in all_sources
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
assert info["LSUIElement"] is True
assert info["LSMinimumSystemVersion"] == "27.0"
assert plistlib.loads((root / "Resources/JimmyTweaks.entitlements").read_bytes()) == {}
print("Source boundary checks passed: scripts has no execution/network/timer API; native agent configuration is minimal.")
