# Jimmy Tweaks

A native macOS 27+ Swift/AppKit background utility for corner resizing, interior window moving, custom global shortcuts, and selected menu bar applications. Icon Absorber is experimental on macOS 27. Reoccurring Scripts contains sample URLs and fictional history only; it does not execute scripts.

The original product contract is in [SPEC.md](SPEC.md); the modules are documented in [Icon Absorber](Docs/IconAbsorber.md) and [Custom Shortcuts](Docs/CustomShortcuts.md). The app has one Settings window, local UserDefaults, seven-day plain-text logs, and a small isolated assertion service used only by Icon Absorber.

## Build and open

Requires macOS 27, an Apple silicon Mac, and Xcode with the macOS 27 SDK. There are no downloaded dependencies.

```sh
./Scripts/build.sh
open "build/Development/Jimmy Tweaks.app"
```

The build script creates a locally ad-hoc signed application with Hardened Runtime. This local build has **not** been Developer ID signed or notarized. You can also open `JimmyTweaks.xcodeproj` and use the shared JimmyTweaks scheme. The generated icon is included in Resources; `Sources/App/BrandIcon.swift` defines the shared gothic J outline for the application and menu bar, and `Scripts/make-icon.swift` packages it at all macOS icon sizes.

`./Scripts/build.sh Release` enables the compile-time Release-only login preference. That preference stays unavailable until the app is Developer ID signed and installed in Applications. Other builds contain no login registration-changing implementation.

## Use

- Open the app to show General. **Permissions** collects Accessibility, Input Monitoring, and Screen Recording guidance, live status, and the corresponding System Settings controls. Each module has hyperlinks that open and highlight the permission entry it uses.
- For a clean permission test, use **Permissions → Reset macOS Permissions and Quit…**. After confirmation, the app stops input handling, cancels owned actions, runs `/usr/bin/tccutil reset All <this build’s bundle identifier>`, and quits. Reopen it to grant access again. The reset targets only this app’s privacy decisions; shortcut definitions, application preferences, Login Items, and other System Settings stay intact. macOS may retain some visible entries. See [Apple’s permission-reset guidance](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos).
- General controls the optional gothic **J** menu bar icon and Suspend All. The matching control-panel examples for all three permissions use a fictional account and generated portrait; they never read your account name or family photos.
- Hold Command and right-drag within a corner area to resize. Corner areas default to 200 logical points (adjustable from 8 to 400). All four corners preserve the opposite corner where the target app accepts geometry changes. Immediate activation is the default.
- Animated effects use abstract iridescent corner energy while hovering/resizing, with a palette independent of the macOS accent colour, and blue mist while moving. Both respond to accepted window velocity and acceleration. Corner energy uses 96-point arms and reconstructs emission between widely spaced resize samples, keeping fast drags continuous. Mist is visible from its first frame, builds quickly, and fades to transparent at the window edges. Stationary, click-through overlays are reused per display, with full-display Metal views and native-resolution drawables. Fire persists in a stationary desktop heat field, so rapid direction changes do not crop its trail at a moving rectangular boundary. Emitter movement is swept analytically in one compute pass per frame. Mist retains its intentional fade at the target window edges.
- Turn off **Animated effects** for steady corner marks and a simple moving outline. macOS **Reduce Motion** disables the checkbox, explains why, and uses static feedback without changing the saved preference. Hidden/static effects have no animation timer. If Metal is unavailable, static feedback is used automatically.
- Overlays are ordered above the matched target window using public window metadata. When metadata is ambiguous, the previous floating overlay behavior is used. No target window is raised or activated.
- Hold Command and left-drag inside the content area to move. The independent threshold defaults to 5 logical points.
- Keep dragging outside the window or over other windows: the original target stays selected until release. Size and position limits do not cancel resizing; reverse direction to continue.
- Release the initiating button to finish moving/resizing. While Command remains held, the effect idles at the final accepted window frame without capturing input, writing window geometry, or retargeting on pointer movement. Releasing Command gradually turns it grey over about one-third of a second, then the grey smoke fades over one second. Switching between moving and resizing preserves the outgoing effect as smoke beneath the incoming animation. Fading smoke stays click-through, and moving the pointer through it clears a soft wake without intercepting input. Reduce Motion and disabled animations skip these transitions. Escape during a gesture attempts to restore the original frame. Suspension, disabled features, and session/permission loss still clear feedback immediately.
- Close Settings to leave the agent running. Reopen the app from Applications to change settings. Suspend All persists between launches; Quit Jimmy Tweaks stops the process.

The window gesture capture path uses Accessibility-authorized modifying event interception and click replay. Input Monitoring is not requested merely because an event tap exists. Optional Icon Absorber icon pictures capture only the native menu-bar window after Screen Recording access is granted. Wallpaper is loaded through NSWorkspace. The app does not record typed keys or fetch sample script URLs.

## Custom Shortcuts

Enable **Custom Shortcuts** and add global keyboard/mouse combinations with ordered actions. Transparent observes input passively; Absorbing shares Window Resizer's active input tap. Press and Release activation are supported. Add native screen selection to clipboard or a cancellable 0.001–60 second Delay, and reorder actions with drag/drop or Up/Down. Different shortcuts run concurrently; Escape cancels them all. Suspend All and module disable also cancel execution. The recorder and Jimmy Tweaks' own windows are excluded. Input Monitoring is requested explicitly when passive observation needs authorization. See [Custom Shortcuts](Docs/CustomShortcuts.md) for permissions, limitations, extension hooks, and the remaining interactive checks.

## Icon Absorber

Open **Icon Absorber** in Settings, select applications, then enable the module. Click an icon in the cropped desktop preview to open that application's original controls. Drag selected applications in the management list to change their order. **Restore All Now**, Suspend All, and quitting release the visibility restriction.

Primary activation uses AXPress. By default the physical icon is restored temporarily and hidden again after the original controls close. The optional **Keep icons hidden when opening controls** mode tries AXPress without restoring it; application support is unverified. Native menus stay in their usual location; only accessible floating panels are candidates for repositioning. Right-click support varies by app.

The private visibility API supports only certain Apple controls. If other system controls are detected, the module pauses and restores everything. Missing wallpaper assets and unavailable icon capture have explicit fallbacks. See the module document for compatibility and the remaining manual tests. Development proceeded after the user explicitly waived the original proof-of-concept gate; those unexecuted tests are not recorded as passed.

Window eligibility depends on public Accessibility attributes. Some apps constrain frame size or position, reject synthesized click replay, change their own focus after geometry updates, or replace cursor feedback. Native full-screen and protected windows are excluded. Threshold activation delays ordinary Command-click delivery until activation is rejected; long-press behavior cannot be perfectly reproduced.

## Project layout

| Folder | Content |
| --- | --- |
| `Sources/Core` | Geometry, pure gesture ownership reducer, typed preferences, search metadata, preview data, file logging |
| `Sources/WindowEngine` | Session event tap, serial Accessibility operations, generation gates, optional nonactivating feedback |
| `Sources/IconAbsorber` | Independent discovery, visibility-service client, original-control invocation and optional icon capture |
| `Helpers/IconAbsorberAgent` | Private assessment API adapter in a disposable process; no watchdog or login registration |
| `Sources/App` | Lifecycle, permission polling, bounded engine recovery, compile-time login preference |
| `Sources/Shortcuts` | Coordinated input routing, floating recorder, action registry, independent cancellable sequences |
| `Sources/Settings` | Eight native pages, taller sidebar search, centralized permission entries and module hyperlinks |
| `Tests` | Deterministic outcome tests, native UI smoke harness, isolated AX fixture, boundary checks |
| `Scripts` | Local build, focused final checks, icon generation, signed distribution workflow |

The AX worker never blocks the event callback. Late work is gated by generation before each write. The reducer tracks pending, active, draining, and ordinary pass-through sequences independently of the native event copies. No application-specific window adapter is installed.

When an asynchronous target lookup relinquishes a click, its bounded down/drag buffer is flushed through the next actual event callback's proxy, before that callback's physical event. This avoids a global-post race in which a queued real mouse-up could overtake a replayed down. There is no unbounded keyboard/input queue.

## Final checks

```sh
./Scripts/test.sh
bash Scripts/test-icon-absorber.sh
python3 Tests/IconAbsorberServiceTests.py "build/Development/Jimmy Tweaks.app/Contents/Helpers/IconAbsorberAgent"
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
