# Jimmy Tweaks

A native macOS 27+ Swift/AppKit background utility for corner resizing, interior window moving, custom global shortcuts, and selected menu bar applications. Icon Absorber is experimental on macOS 27. Reoccurring Scripts contains sample URLs and fictional history only; it does not execute scripts.

The original product contract is in [SPEC.md](SPEC.md); the modules are documented in [Icon Absorber](Docs/IconAbsorber.md) and [Custom Shortcuts](Docs/CustomShortcuts.md). The app has one Settings window, local UserDefaults, seven-day plain-text logs, and a small isolated assertion service used only by Icon Absorber.

## Build and open

Requires macOS 27, an Apple silicon Mac, and Xcode with the macOS 27 SDK. There are no downloaded dependencies.

```sh
./Scripts/build.sh
open "build/Development/Jimmy Tweaks.app"
```

The build script creates a locally ad-hoc signed application with Hardened Runtime. This local build has **not** been Developer ID signed or notarized. You can also open `JimmyTweaks.xcodeproj` and use the shared JimmyTweaks scheme. The Celtic living-wood application artwork is in `Resources/AppIcon.png`; `Sources/App/BrandIcon.swift` draws the simplified monochrome J for the menu bar, and `Scripts/make-icon.swift` packages the artwork at all macOS icon sizes.

`./Scripts/build.sh Release` enables the compile-time Release-only login preference. That preference stays unavailable until the app is Developer ID signed and installed in Applications. Other builds contain no login registration-changing implementation.

## Use

- Open the app to show General. Missing Accessibility, Input Monitoring, and Screen Recording access is requested automatically once per launch. **Permissions** collects guidance, live status, and the corresponding System Settings controls; it checks every two seconds while visible and any access is missing. Each module has hyperlinks that open and highlight the permission entry it uses.
- **Visual Effects** holds the gesture effect controls in **Move/Resize** and continuous screen-wide effects in **Static**. Choose No Effect, Rain, Fireflies, or Snow Storm. Each running effect has its own saved controls in a fixed-height area. Static effects ignore clicks and pause for Suspend All, Reduce Motion, sleep, or an inactive session. Existing Snowfall selections automatically switch to Snow Storm.
- **Snow Storm** falls from screen tops and merges into uneven snowbanks on visible window tops and the cursor. Each part of a window top has its own stable limit, no higher than 24 points, so a full bank stays lumpy instead of becoming a rectangular slab; cursor snow is capped at 12 points. Snowbanks follow their window’s stacking order. The screen-wide snowfall sits behind each display’s frontmost window. Snowfall intensity controls the number of flakes and, near its maximum, makes them fall several times faster. Wind gusts alone controls sideways bursts, snow entering from the upwind screen edge, and occasional circular vortices at screen edges. A moving window nudges intercepted flakes to its edge; some flakes pass in front of each window and can settle on a lower top. Ordinary dragging carries settled snow with the window. A small sideways shift lets snow at the edge spill, while quick repeated shakes release a modest amount as falling flakes. Snow Storm uses public rectangular window geometry and samples the visible system cursor’s opaque pixels once on startup for cursor snow collisions; if the cursor image cannot be read, it uses the older small shelf.
- Snow Storm has independent **Decorations** and **Lights** checkboxes beside Fireplace. Turn them on whenever you want miniature trees, presents, snowmen, carolers, or old-style incandescent bulbs on sagging green wire below normal app windows' top edges. Some bulbs are dark or briefly flicker. On Christmas Eve, Santa periodically flies behind the windows with reindeer, lands by a chimney, and climbs down. A double-click on the **Decorations** text summons one Santa visit on any date; it does not change the checkbox.
- Snow Storm’s optional **Fireplace** checkbox builds an open-bottom brick surround behind the Dock. The surround starts about 30% wider than the current Dock and expands for magnification or additional icons, retaining the larger size while enabled. The firebox leaves room above a visible Dock for a centred pile of glowing logs spanning about 80% of the opening; faster, narrower flames rise from that pile. The Dock stays visible and clickable in front. It supports bottom and side Docks, using a fixed bottom-centred size before visible Dock geometry is available. Turning it off breaks the bricks apart into grey smoke behind the Dock; the saved choice is retained when selecting another Static effect.
- For a clean permission test, use **Permissions → Reset macOS Permissions and Quit…**. After confirmation, the app stops input handling, cancels owned actions, runs `/usr/bin/tccutil reset All <this build’s bundle identifier>`, and quits. Reopen it to grant access again. The reset targets only this app’s privacy decisions; shortcut definitions, application preferences, Login Items, and other System Settings stay intact. macOS may retain some visible entries. See [Apple’s permission-reset guidance](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos).
- General controls the optional Celtic **J** menu bar icon and Suspend All. The matching control-panel examples for all three permissions use a fictional account and generated portrait; they never read your account name or family photos.
- General also offers **Control volume from the menu bar icon** (off by default): wheel up/down changes the current default sound output, and middle-click toggles mute. Trackpad movement is accumulated, inertial scrolling is ignored, and natural scrolling is normalized. Device/channel balance is preserved, and devices without hardware mute can use a saved-volume mute. Fixed-volume outputs report their limitation in the icon tooltip. Left/right clicks keep opening the normal menu. Suspend All pauses these controls.
- General keeps its taller sidebar row; the other sections use compact rows. Each has a playful custom icon with Standard, Dark, Clear, and Tinted variants. The sidebar follows the observed macOS Icon & Widget Style preference while visible, including custom tint colors, with standard artwork as a safe fallback. These are native in-app drawings, not a system Icon Composer API.
- Open **Window Move & Resize** to adjust the shared **Edge Zone Size**, measured inward from every window edge (default 200 logical points, adjustable from 8 to 400). Hold Command and right-drag in this outer band to resize from the nearest corner. The centre starts immediately beyond the band, with no gaps or overlaps. On shorter windows the band automatically narrows to preserve a usable moving centre. All four corners preserve the opposite corner where the target app accepts geometry changes. Immediate activation is the default.
- In **Visual Effects > Move/Resize**, each **Effect** dropdown starts with **No Effect**. Resize offers **Iridescent Energy** (the original default), **Furious Lightning**, and **Ember Flame**. Moving offers **Blue Mist** (the original default), **Aurora Veil**, **Starlight Swirl**, and **Cartoon Wind**. Selections persist independently. Command-gesture resize animations also require **Show Corner Hints**; No Effect leaves the separate static hint or optional outline available. **Show effects for normal window drags** is off by default. When enabled, the app watches normal left-button title-bar moves and edge resizes, showing the chosen effect only after the window's own position or size changes. These mouse events pass through unchanged, and no window frame is written by the observer.
- Resize visuals begin only when a **Command + right-button** resize gesture activates. Command-only hover may change the cursor but starts no corner marker or animated effect. **After Small Drag** waits for its configured threshold before showing resize visuals.
- **Furious Lightning** sends eight independently timed electrical fingers outward from the window edges. Some roots stay pinned for a while and then collapse; others walk chaotically along the perimeter and around corners. Tips independently alternate between gentle probing and violent sweeps. Each leader starts with a broad white-hot base and tapers to fine violet-white streamers. Following the Tesla-coil video reference, a finger retains its near-root route while newly fractured distal channels and branching crowns repeatedly grow and reform. Brief overlapping restrikes leave a short afterimage, and compact violet corona glows mark the attachment points. Fingers have separate lifetimes, motion targets, and random streams. Their collapses and behaviour changes are staggered. Collapse extinguishes an existing crooked channel back toward its root instead of scaling or rotating a fixed outline. Release stops new fingers and lets the remaining charge and free sparks fizzle away.
- **Cartoon Wind** is a persistent particle field containing broad diffuse grey-white ribbons, narrower solid streaks, dust, and occasional orange, yellow, and red leaves. Its front extends beyond the window's height or width and keeps the central content clear. Wind density is four times the original: 580 particles per second, with a 1,680-particle live limit. Each particle retains its world position, birth velocity, age, and lifetime. Turning or moving the window changes only newly emitted wind; older gusts continue along their previous trajectories while the new vector builds. Release stops emission, and existing particles drift and fade over their remaining lifetimes, up to 2.6 seconds.
- Animated effects respond to accepted window velocity and acceleration. The original corner energy uses 96-point arms and reconstructs emission between widely spaced resize samples, keeping fast drags continuous. Mist is visible from its first frame, builds quickly, and fades to transparent at the window edges. Stationary, click-through overlays are reused per display, with full-display Metal views and native-resolution drawables. Energy and flame persist in a stationary desktop heat field, so rapid direction changes do not crop their trails at a moving rectangular boundary. Wind and lightning use independently rendered particles and arc segments. Emitter movement is swept analytically in one compute pass per frame. Interior moving effects retain their intentional fade at the target window edges; Cartoon Wind intentionally extends outside the frame.
- Turn off **Animated effects** for steady corner marks and a simple moving outline. macOS **Reduce Motion** disables the checkbox, explains why, and uses static feedback without changing the saved preference. Hidden/static effects have no animation timer. If Metal is unavailable, static feedback is used automatically.
- Overlays are ordered above the matched target window using public window metadata. When metadata is ambiguous, the previous floating overlay behavior is used. No target window is raised or activated.
- Hold Command and left-drag in the centre beyond the shared edge zone to move. The independent threshold defaults to 5 logical points.
- Keep dragging outside the window or over other windows: the original target stays selected until release. Size and position limits do not cancel resizing; reverse direction to continue.
- Release the initiating button to finish moving/resizing. While Command remains held, the effect idles at the final accepted window frame without capturing input, writing window geometry, or retargeting on pointer movement. Releasing Command lets Cartoon Wind drift and unwind away, lets Furious Lightning fizzle into a fading electrical residual, and turns other styles grey over about one-third of a second before their smoke fades over one second. Switching between moving and resizing preserves the outgoing effect's departure beneath the incoming animation. Fading smoke stays click-through, and moving the pointer through it clears a soft wake without intercepting input. Reduce Motion and disabled animations skip these transitions. Escape during a gesture attempts to restore the original frame. Suspension, disabled features, and session/permission loss still clear feedback immediately.
- Close Settings to leave the agent running. Reopen the app from Applications to change settings. Suspend All persists between launches; Quit Jimmy Tweaks stops the process.

The window gesture capture path uses Accessibility-authorized modifying event interception and click replay. Input Monitoring supports Transparent shortcuts and the global recorder; it does not block window gestures. Optional Icon Absorber icon pictures capture only the native menu-bar window after Screen Recording access is granted. Wallpaper is loaded through NSWorkspace. The app does not record typed keys or fetch sample script URLs.

## Custom Shortcuts

Enable **Custom Shortcuts** and add global keyboard/mouse combinations with ordered actions. Transparent observes input passively; Absorbing shares Window Move & Resize's active input tap. Press and Release activation are supported. Add native screen selection to clipboard or a cancellable 0.001–60 second Delay, and reorder actions with drag/drop or Up/Down. Different shortcuts run concurrently; Escape cancels them all. Suspend All and module disable also cancel execution. The recorder and Jimmy Tweaks' own windows are excluded. Missing Input Monitoring access is requested at launch. See [Custom Shortcuts](Docs/CustomShortcuts.md) for permissions, limitations, extension hooks, and the remaining interactive checks.

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

Active window updates tolerate a transient Accessibility communication failure: the same target gets one bounded retry with a fresh frame read and a longer per-window response allowance. Already-applied writes are reconciled rather than applying movement twice. Cancellation, permission loss, and permanent errors still stop writes. Retry and failure logs now identify whether reading or writing the position or size failed.

The AX worker never blocks the event callback. Late work is gated by generation before each write. The reducer tracks pending, active, draining, and ordinary pass-through sequences independently of the native event copies. No application-specific window adapter is installed.

Resizing makes room before growing toward the top or left and defers movement toward the bottom or right until after shrinking. This prevents a temporary frame from being clipped against the opposite screen edge or Dock even when the requested final frame fits. Accepted frames need no repeated writes, and a constrained position is retried only if its write changed the window's size.

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
