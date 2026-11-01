# Jimmy Tweaks — Validation Record

Checks performed: October 29, 2026. Delivery packaged: October 30, 2026. All application builds and test runs were deferred until the initial implementation was in place, as requested.

## Environment

- macOS 27.0.1 on Apple silicon (`arm64`).
- Xcode 27, macOS 27.0 SDK, Apple Swift 6.4 compiler.
- Minimum deployment target: macOS 27.0.
- No Developer ID signing identity was configured on this machine.

## Completed checks

| Check | Observed result |
| --- | --- |
| Standalone Development build | Passed; native executable and local app bundle produced |
| Standalone Release build | Passed; compile-time login implementation included |
| Shared Xcode project/scheme, Release | `BUILD SUCCEEDED` with distribution signing disabled for the build check |
| Deterministic behavior suite | **2,092 / 2,092 checks passed**, including 2,000 generated opposite-anchor geometry cases |
| Native UI smoke harness | Passed for all seven Settings pages, default thresholds, 960 × 700 layout, minimum usable width, per-control search destinations, Return activation, and empty search state |
| Scripts boundary regression checks | Passed: no process, interpreter, networking, workspace-open, timer, or scheduling APIs in the scripts model/page |
| Native application configuration | Passed: macOS 27 deployment, hidden agent, single normal instance, one executable, minimal entitlements |
| Compile-time login boundary | Verified that login-service symbols are absent from Development and present in Release |
| Local signing | Ad-hoc signature and Hardened Runtime present; strict code-signature verification passed |
| Build/distribution/test scripts | Shell syntax checks passed |
| Property lists and icon | Plists passed lint; generated ICNS recognized by the OS image tool |
| Live first-run interface | Opened the app; Welcome and permission guidance appeared; Skip Setup dismissed the assistant and left Settings usable |
| Live permission status | Reported that Accessibility trust was available but input control was unavailable; affected functionality stayed blocked |
| Live search inspection | “move threshold” returned the specific moving threshold with its breadcrumb and current 5-point value |

The deterministic suite covers positive/cross-anchor dimensions, negative/fractional coordinates, Euclidean threshold boundaries, immediate/threshold ownership, subthreshold replay decisions, Command release, draining, Escape key pairing, stale resolution, suspension admission, preference repair/reset batching, search normalization/ranking, scripts syntax-only validation, retry limits, log retention boundary pruning, and serialized log appends.

The native smoke harness uses in-memory application preferences, a supplied scratch log directory, and a suspended runtime. It does not grant permissions or register a login item. The optional native AX fixture compiled successfully. Some system-service diagnostics appeared when native UI tests ran inside the restricted command environment; the harness completed successfully. A separate live UI inspection confirmed the real application opens normally.

## Checks still requiring an interactive permitted installation

These are **not claimed as passed**:

- Live system-wide resizing/moving against Finder, browsers, TextEdit, Terminal, dialogs, floating panels, constrained-size windows, and a non-AppKit app. The input-control capability was unavailable during this session, and no security grant was made by the agent.
- End-to-end inactive-app focus preservation, cursor arbitration, AX constraint reconciliation, click replay through third-party input tools, and long physical button holds during tap loss.
- Real permission grant/revocation, tap fault injection, and bounded recovery against OS-controlled failures. Pure state/geometry/retry outcomes are covered; actual system tap behavior is separate.
- Multiple physical displays and scale factors, display removal, Space changes, lock, sleep/wake, and fast user switching during an active gesture.
- Full VoiceOver operation, complete keyboard-only navigation, and additional accessibility appearance configurations.
- Five-minute idle CPU measurement, p95 gesture latency on a cooperative target, and the 500-gesture leak/reliability run.
- Actual login registration and approval with an installed Developer ID signed Release app, followed by silent sign-in startup and persistent suspension validation.
- Developer ID signing, Apple notarization, stapling, clean-account quarantined installation, and offline Gatekeeper acceptance of the actual signed distribution. The included distribution workflow is prepared but could not be executed without the owner's signing/notarization credentials.

## Delivery status

The delivered executable is a locally built, ad-hoc signed application. It is **not a notarized public release**. The source includes the full native implementation, focused tests, fixture, build scripts, distribution workflow, installation notes, and the specification. Reoccurring Scripts remains intentionally nonfunctional.

Quit any earlier test copy before opening a different copy of the local application; independently installed duplicate copies with the same local identifier are not a supported configuration. Before external distribution, set the final owned bundle identifier and complete the remaining applicable acceptance scenarios in SPEC.md.

## October 30 gesture continuation update

- Default resize corner size is now 200 logical screen points, adjustable from 8 to 400.
- Removed cancellation after repeated constrained anchor positions. A drag retains its initial target and corner outside the window and continues through size/position limits, with one bounded corrective position write per transaction.
- Returning the pointer to its starting position reapplies the original frame instead of skipping the update after an earlier resize or move.
- Development build passed. **2,172 / 2,172 focused checks** and the native UI smoke harness passed, including new checks for outside-window drags, all four corners, repeated constraints, reversal, returning to the initial pointer, and the 200-point default.
- Full physical dragging with the updated app still requires an interactive retry; these automated checks do not establish live application compatibility.

## October 30 local Accessibility hit-test fix

Xcode's paused stack identified `AXUIElementCopyElementAtPosition` on the Accessibility worker as the entry into the reported background-thread layout fault. The system-wide hit test now runs asynchronously on main and rejects our own process before worker-side attribute traversal. Foreign-window resolution and geometry writes remain on the serial worker.

The Development build and 2,172 focused checks passed. The native UI smoke harness additionally verifies main-thread hit testing when resolution starts on a background queue, rejection of our own UI, and closing/reopening Settings while the runtime remains alive. Closing Settings continues to leave the agent running; explicit Quit performs shutdown.

## October 30 review fixes

All six findings from the subsequent full code review are addressed:

- Disabling moving or resizing clears final-write cleanup after mouse-up, allowing the other enabled gesture to start. Controlled worker checks cover cancellation before and during the final write.
- Context-boundary discard removes deferred native click buffers and drains their initiating release. Checks cover an already-pending ordinary stop and a release arriving before the queued stop block. Runtime stop requests can escalate to discard.
- Own-process Accessibility hits are rejected before attribute traversal. The UI harness verifies main-thread hit testing, the local process identity, and zero attribute reads for that hit.
- Explicit log flush and shutdown drain buffered records after writer recovery, including within the automatic retry cooldown. Controlled file-failure checks verify records are written once and in order.
- Script search metadata tracks current rows after removal and reset; previously rendered row results explain removal. Table refresh preserves the selected sample.
- Preference resets clear numeric validation errors and invalid drafts even when the stored preference already equals its default. Ordinary refreshes preserve rejected drafts for correction.

Validation passed: **2,178 / 2,178 focused checks**, controlled engine regressions, native UI smoke tests, scripts boundary checks, shell syntax checks, Development and Release builds, and strict code-signature verification for both local app bundles. Test-only inspection hooks are absent from both application binaries. The engine regressions inject worker completions without installing a system event tap or granting permissions. The interactive acceptance checks listed above remain outstanding.

## Custom Shortcuts — October 31, 2026

Implemented the native module, recorder, coordinated passive/active routing, action registry and picker, independently cancellable sequences, Delay, native clipboard screen selection, and global Escape notification. The planned Scripts preview remains inert.

| Check | Result |
| --- | --- |
| Standalone Development and Release builds, macOS 27 / arm64 | Passed |
| Xcode shared scheme, Development, signing disabled for the build check | `BUILD SUCCEEDED`; isolated `build/ShortcutXcode` derived data |
| Local Development and Release bundle signatures | Strict verification passed; ad-hoc, not notarized |
| Existing focused core checks | 2,182 / 2,182 passed |
| New Custom Shortcuts checks | 171 passed: recording, matching, conflicts, persistence, execution concurrency/order, cancellation, owned-process termination, permission prompting and active/passive routing |
| Native UI smoke | Seven pages passed; populated shortcut editing, persisted Up/Down ordering, decimal Delay field, action-picker search, and existing Settings behaviors |
| Existing Window Resizer engine regressions | Passed: final-write disable and balanced deferred replay/discard |
| Existing Icon Absorber tests | 17 checks plus real helper clear-acknowledgement and service-kill/write-race checks passed; no live hiding |
| Source boundaries and diff whitespace | Passed |

No real screen selection, physical input capture/interception, security grant/revocation, or live cross-application event delivery was performed. Automated events were passed directly to the production matcher/router rather than posted globally; the owned-process cancellation test used a disposable `/bin/sleep` child. Native UI tests emitted restricted-environment macOS service diagnostics and completed successfully. Interactive checks, including drag/drop and screenshot clipboard/cancellation behavior, remain listed in [Custom Shortcuts](Docs/CustomShortcuts.md#verification).

### Add Action window fix — November 1, 2026

The action picker is now a key-capable owned utility panel, presented above Settings with explicit activation and search focus. Repeated Add Action clicks reuse the same controller/window. Cancel, Escape, the title-bar close button, and closing Settings use the same ownership cleanup; a closed picker can be reopened without retaining an unresponsive older window. Changing the selected shortcut also closes an obsolete picker.

`Scripts/test.sh` passed with regression checks for visibility/key eligibility, search focus, repeated-open identity, Cancel, title-bar close, reopening, and parent-close cleanup, in addition to the existing 2,182 core and 171 shortcut checks. The tests use native AppKit windows and isolated shortcut preferences.

### Centralized Permissions — November 1, 2026

Added the Permissions sidebar page with Accessibility, Input Monitoring, and Screen Recording entries. System Settings launch buttons, the existing access illustration, grant status labels, and the explicit Input Monitoring request now live there. Window Resizer, Icon Absorber, and Custom Shortcuts use native hyperlinks to navigate to, scroll to, and highlight the relevant entry. Capture-action permission links are supplied through action-registry metadata. Permission status polling follows the visible Permissions page, and Screen Recording uses a nonprompting preflight check.

Development, Release, and the Xcode Development builds passed, with strict verification of both local app signatures. `Scripts/test.sh` passed 2,182 focused checks, 173 shortcut/permission checks, and the eight-page UI smoke suite. The UI suite exercises all six module-to-permission links, target visibility/highlighting, searchable permission entries, and removal of permission controls from General. Repeated navigation also verifies that older highlight timers cannot clear the current target. The Icon Absorber suite passed its 17 checks and helper-client regressions with updated permission guidance. No system permission grants were changed by these checks.

### App-scoped permission reset — November 1, 2026

Added **Reset macOS Permissions and Quit…** at the top of Permissions. Confirmation requests the normal app termination path; permission polling stops, Icon Absorber releases its service, input handling stops, and owned actions receive cancellation before `/usr/bin/tccutil reset All <current bundle identifier>` runs. The command requires a validated, explicit app identity, never falls back to a system-wide reset, and has a bounded timeout. Utility failures are logged and displayed before quitting. Shortcut definitions and application preferences are preserved. This resets supported privacy decisions; it does not promise removal of every visible System Settings row or changes to Login Items.

Development, Release, and Xcode Development builds passed. `Scripts/test.sh` passed 2,182 focused checks, 185 shortcut/permission checks, and the eight-page UI smoke suite. New checks cover exact command scoping, rejection of missing/invalid identities, failure reporting, and confirmation routing. The reset executor was replaced with a fake in tests; no actual privacy permissions were reset. Both local app bundle signatures passed strict verification.

### Full review fixes — November 1, 2026

- Ordinary Quit now waits for action cancellation as well as input-engine cleanup. A disposable child of the native test harness ignores SIGTERM, and the regression confirms shutdown stays pending until the owned process's delayed SIGKILL and task cleanup finish. Cancellation remains bounded to three seconds; a failed cancellation prevents a requested permission reset.
- Icon Absorber rechecks cancellation after reading the owner's AX windows and after right-click hit testing. Injected operation boundaries verify that cancellation prevents AXPress, AXShowMenu, and mouse posting, while an already-admitted right-click pair stays balanced. No real status item is invoked by these checks.
- Recorder completion updates the shortcut that opened it, including after selection changes. Removing that shortcut discards the recording. Native UI regressions cover both outcomes.
- Return and arrow commands apply the latest pending Settings search query first. Regressions cover an edited query, first-query submission before the debounce fires, repeated arrow selection, whitespace queries, and cancelled delayed refreshes.
- The two previously unwired permission transition cases now run through `Scripts/test.sh`, adding 13 checks with injected permission probes and requests.

Validation passed: 2,182 core checks, engine regressions, 185 shortcut/permission checks, the 13 permission transition checks, Settings regressions, eight-page UI smoke, 29 Icon Absorber checks, helper client/service protocol checks, and 87 effects checks. Development, Release, and Xcode Development builds passed; both standalone app signatures passed strict verification. The effects suite ran outside the restricted sandbox to support its native fixture and Metal checks. Existing interactive acceptance gaps remain outstanding; no actual privacy reset, security grant, login registration, screenshot selection, or live icon hiding was performed.

### Icon Absorber preview invocation — November 1, 2026

Preview buttons now invoke restored original status items during a hiding compatibility pause or visibility-helper failure. They retain the existing module, suspension, session, capture, and Accessibility gates. Optional panel-position metadata no longer prevents the primary action from being routed. A separate preview status shows progress, persistent invocation errors, undetected interfaces, and reasons for disabled controls. A helper response without an active restriction no longer claims items are absorbed. Right-click respects a disabled preview button.

The new native UI regression uses the actual page/buttons/controller with injected AX operations, surfaces, permission probes, and time. It verifies click routing during compatibility pause and missing-helper failure, preservation of the hiding guard, persistent rejected-action feedback, no-interface detection, observed surface open/close, suspension for both mouse buttons, permission revocation, and removal of stale opening messages after cancellation. It never invokes a real status item or holds a visibility assertion.

The main suite passed 2,182 core checks, 13 permission transition checks, 185 shortcut checks, engine/Settings/preview regressions, and eight-page UI smoke; the separate Icon Absorber suite passed 29 checks and helper-client regressions. Development, Release, and Xcode Development builds and standalone signature verification passed. Live invocation against third-party controls remains unverified: the inspected desktop build reported Accessibility denied. The user's saved experimental hidden-AXPress option was enabled; it was not changed automatically.

### Version 1.0.0 release preparation — November 1, 2026

Built the current source with `Scripts/build.sh Release` for Apple silicon and macOS 27+. Re-ran the main suite (2,182 core, 13 permission transition, 185 shortcut checks, engine/Settings/preview regressions, and eight-page UI smoke), the 29 Icon Absorber checks and helper-client regressions, and the real Release helper's service protocol checks. All passed. The effects suite passed all 87 checks outside the sandbox after the restricted run could not start its native fixture.

Packaged the app as `Jimmy-Tweaks-1.0.0-macos-arm64.zip` with a SHA-256 checksum. ZIP integrity, strict nested code-signature verification of both the original and extracted app, and byte-for-byte comparison of the extracted executable passed. This Release build uses the existing local bundle identity and ad-hoc signing; no Developer ID identity or notarization profile is configured. It is not notarized, and the interactive acceptance gaps above remain open.
