# Jimmy Tweaks

A native macOS 27+ Swift/AppKit background utility for corner resizing and interior window moving. Reoccurring Scripts is deliberately a **NONFUNCTIONAL UI STUB**: sample URLs and fictional history only.

The complete product contract is in [SPEC.md](SPEC.md). The app has one executable, no bundled helper, one Settings window, local UserDefaults, and seven-day plain-text logs.

## Build and open

Requires macOS 27, an Apple silicon Mac, and Xcode with the macOS 27 SDK. There are no downloaded dependencies.

```sh
./Scripts/build.sh
open "build/Development/Jimmy Tweaks.app"
```

The build script creates a locally ad-hoc signed application with Hardened Runtime. This local build has **not** been Developer ID signed or notarized. You can also open `JimmyTweaks.xcodeproj` and use the shared JimmyTweaks scheme. The generated icon is included in Resources; `Scripts/make-icon.swift` is its source.

`./Scripts/build.sh Release` enables the compile-time Release-only login preference. That preference stays unavailable until the app is Developer ID signed and installed in Applications. Other builds contain no login registration-changing implementation.

## Use

- Open the app to show Settings. Follow or skip the permission assistant. It can be reopened from Status or Permissions.
- Hold Command and right-drag within a corner area to resize. Corner areas default to 200 logical points (adjustable from 8 to 400). All four corners preserve the opposite corner where the target app accepts geometry changes. Immediate activation is the default.
- Hold Command and left-drag inside the content area to move. The independent threshold defaults to 5 logical points.
- Keep dragging outside the window or over other windows: the original target stays selected until release. Size and position limits do not cancel resizing; reverse direction to continue.
- Release Command or the initiating button to finish. Escape attempts to restore the original frame.
- Close Settings to leave the agent running. Reopen the app from Applications to change settings. Suspend All persists between launches; Quit Jimmy Tweaks stops the process.

The capture path uses Accessibility-authorized modifying event interception and click replay. Input Monitoring is not requested merely because an event tap exists. The app does not capture screen content, record typed keys, or fetch sample script URLs.

Window eligibility depends on public Accessibility attributes. Some apps constrain frame size or position, reject synthesized click replay, change their own focus after geometry updates, or replace cursor feedback. Native full-screen and protected windows are excluded. Threshold activation delays ordinary Command-click delivery until activation is rejected; long-press behavior cannot be perfectly reproduced.

## Project layout

| Folder | Content |
| --- | --- |
| `Sources/Core` | Geometry, pure gesture ownership reducer, typed preferences, search metadata, preview data, file logging |
| `Sources/WindowEngine` | Session event tap, serial Accessibility operations, generation gates, optional nonactivating feedback |
| `Sources/App` | Lifecycle, permission polling, bounded engine recovery, compile-time login preference |
| `Sources/Settings` | Native split view/sidebar, per-control search, utility pages, skippable assistant |
| `Tests` | Deterministic outcome tests, native UI smoke harness, isolated AX fixture, boundary checks |
| `Scripts` | Local build, focused final checks, icon generation, signed distribution workflow |

The AX worker never blocks the event callback. Late work is gated by generation before each write. The reducer tracks pending, active, draining, and ordinary pass-through sequences independently of the native event copies. No application-specific window adapter is installed.

When an asynchronous target lookup relinquishes a click, its bounded down/drag buffer is flushed through the next actual event callback's proxy, before that callback's physical event. This avoids a global-post race in which a queued real mouse-up could overtake a replayed down. There is no unbounded keyboard/input queue.

## Final checks

```sh
./Scripts/test.sh
```

The tests use isolated in-memory preferences and a supplied scratch directory. They do not grant permissions or register login startup. `Tests/Fixtures/WindowFixture.swift` is optional test tooling for deliberate manual AX compatibility checks; it is not shipped inside the application. See `VALIDATION.md` for the actual checks completed on this machine and the remaining manual acceptance matrix. A passing build or deterministic test suite is not a claim that every third-party app has been tested.

## Developer ID distribution

Choose a real, stable reverse-DNS bundle identifier owned by the distribution owner. The default `local.jimmytweaks.app` is intentionally a local-build identity. Before users grant permissions to a distributed version, settle its bundle identifier and signing identity; changing them can change macOS permission association.

With a configured Developer ID Application identity and an existing `notarytool` keychain profile:

```sh
export BUNDLE_IDENTIFIER='your.owned.identifier'
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (YOURTEAMID)'
export NOTARY_PROFILE='your-existing-notary-profile'
./Scripts/distribute.sh
```

The script builds Release, signs and notarizes the app, staples its ticket, creates a disk image with installation instructions, signs and notarizes that image, staples it, and verifies system assessment. It uses the owner's existing credentials; no keys, passwords, certificates, or account identifiers are embedded in the source. It does not create a signing identity or alter account security settings.

No Developer ID identity was configured on the creation machine, so a local build must not be represented as a notarized distribution. Clean-account permission tests, login approval, and offline Gatekeeper acceptance must be completed with the actual signed distribution before public delivery. Independently installed duplicate copies with different identities are unsupported.

## Local data

Preferences use the application's UserDefaults domain. Logs are UTF-8 under `~/Library/Logs/Jimmy Tweaks/`, with daily/5 MiB segments, hourly seven-day cleanup, and atomic pruning of the boundary segment. Open Log File flushes and opens the current file in the default text app. File errors do not stop window manipulation. Scripts preview edits and fictional history changes are memory-only and disappear when the process exits.
