# Icon Absorber: isolated Phase 1 proof of concept

**Result: UNVERIFIED. Phase 2 and later are blocked.**

The native probe was built and launched on macOS 27.0.1, build 26A434,
Apple silicon. The private framework and expected Objective-C method signatures
are present. Initial discovery was blocked by missing privacy permissions.

After the user granted permission, the desktop probe reported Accessibility and
input posting available and discovered both original status items. A hiding
assertion was accepted at 21:52:50 UTC, then released at 21:52:51 UTC by the
running-application-change guard. A simulated left click was posted after release;
the original controls' appearance/usability was not visually verified. Restore All
was called at 21:53:14 UTC. See [retry evidence](Evidence/desktop-retry.txt).

Visual hiding, original-control usability, restoration, crash recovery and
isolation still require verification. The app is left open with the restriction
released. The computer-use screenshot of MenuBarAgent did not reveal the actual
status-item glyphs, and MonitorControl's screenshot exposed only its tiny gamma
enforcer window. Those observations cannot establish the required visual results.
Complete the real tests below before proceeding.

## Scope and repository inspection

Production Jimmy Tweaks sources, project, preferences and build scripts are
untouched. This directory is outside `Sources`, so the normal build script's
recursive Swift source collection does not include it. The Xcode project does not
reference it. The probe is a separate executable and bundle, not a production helper.

The inspected application targets macOS 27.0 and arm64, uses Swift 5 language mode,
AppKit, a single executable, Hardened Runtime, and no App Sandbox. Development
builds are ad-hoc signed. `AppDelegate` constructs a shared `SettingsContext` and
`RuntimeCoordinator`; the latter manages Window Resizer/Window Mover permissions,
session state, retry budgets and shutdown. Settings pages are native view
controllers. Preferences use typed keys, local UserDefaults and change
notifications. There is no general plug-in/module registry to extend blindly.
`AccessibilityWindows` already owns serial, generation-gated window operations.
Its existing code is not reused or changed by this experiment.

The supplied directory has **no `.git` metadata or upstream remote** (`git status`
reports that it is not a repository). No commits or PR were created. In the actual
version-controlled checkout, create `codex/icon-absorber-poc` before importing
these additive files:

```sh
git switch -c codex/icon-absorber-poc
```

Do not manufacture a new upstream history for this source snapshot. A feature PR
is conditional on a passing proof of concept and completed integration.

## Mechanism research

Reviewed baaar at commit `fcecf22d75a5fd88963c3cb3fc71a5d2a852cd7f`:

- [`VisibilityRestriction.swift`](https://github.com/bylaaabs/baaar/blob/fcecf22d75a5fd88963c3cb3fc71a5d2a852cd7f/baaar/MenuBar/VisibilityRestriction.swift)
  loads `MenuBarClientCore` dynamically and holds an assessment assertion with an
  allow-list of running bundles excluding the selected applications.
- [`Settings.swift`](https://github.com/bylaaabs/baaar/blob/fcecf22d75a5fd88963c3cb3fc71a5d2a852cd7f/baaar/Support/Settings.swift)
  defines reverse-engineered system item identifiers 0–8: battery, Bluetooth,
  clock, displays, keyboard brightness, sound, Wi-Fi, screen mirroring and Control Center.
- [`ItemScanner.swift`](https://github.com/bylaaabs/baaar/blob/fcecf22d75a5fd88963c3cb3fc71a5d2a852cd7f/baaar/Items/ItemScanner.swift)
  discovers original items using each process's Accessibility extras menu bar.
- [`MenuBarController.swift`](https://github.com/bylaaabs/baaar/blob/fcecf22d75a5fd88963c3cb3fc71a5d2a852cd7f/baaar/MenuBar/MenuBarController.swift)
  temporarily restores a bundle, waits for its item to settle, invokes `AXPress`,
  and watches menus/popovers before re-hiding. A hidden frame is not a trustworthy
  click target. This is invocation of the owning app, not menu reconstruction.
- [`20-decision-log.md`](https://github.com/bylaaabs/baaar/blob/fcecf22d75a5fd88963c3cb3fc71a5d2a852cd7f/docs/20-decision-log.md)
  records the assertion approach and its system-control side effects.

For comparison, reviewed Ice at commit
`11edd39115f3f43a83ae114b5348df6a0e1741cf`:
[`ControlItem.swift`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/ControlItem/ControlItem.swift)
uses an expanded 10,000-point status item to displace items, while
[`MenuBarItemManager.swift`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift)
uses item window IDs and synthesized events. That implementation is not evidence
of compatibility with this Mac's menu bar. baaar's source describes the macOS 27
transition to a single menu-bar window; that architectural claim was not
independently runtime-verified here.

### Public versus private

Apple documents [`NSStatusBar`](https://developer.apple.com/documentation/appkit/nsstatusbar)
and [`NSStatusItem`](https://developer.apple.com/documentation/appkit/nsstatusitem)
for creating and controlling an application's own status items. They provide no
documented general service for hiding arbitrary foreign status items.

The installed public macOS SDK declares `kAXExtrasMenuBarAttribute`,
`AXUIElementCopyAttributeValue`, `AXUIElementPerformAction`, `kAXPressAction`,
`kAXShowMenuAction`, `AXUIElementCopyElementAtPosition`, `AXIsProcessTrusted`,
`CGPreflightPostEventAccess` and CGEvent mouse posting. These are public
Accessibility/Quartz APIs, subject to permissions and the target's behavior.
`AXShowMenu` is an accessibility semantic action, not proof of a physical right
click. The probe has separate real synthesized mouse-button paths.

`MenuBarClientCore`, `MBAssessmentModeConfiguration`,
`MBAssessmentModeAssertion`, their selectors and system item integer values are
**private and unsupported**. Presence and matching signatures were checked by
loading the framework and inspecting the actual Objective-C runtime. Activation,
entitlement requirements, service behavior and process-death cleanup remain
unverified on this machine. Another project's successful use is not our result.

The adapter checks signatures before invoking methods and catches Objective-C
exceptions. That cannot contain a native fault or guarantee future ABI safety.
It is deliberately isolated in this separate probe process. Production fault
containment has not been designed or validated.

### Isolation concern requiring a real decision

baaar's source explicitly reports that an active restriction can remove Apple
modules outside the nine enumerated items (for example Focus or Fast User
Switching) and prevent Notification Center opening from the clock. Allowing all
running Apple bundle IDs does not establish that those module restrictions vanish.
baaar has a clock-click workaround that temporarily lifts the restriction.

The probe deliberately does not conceal these effects with a workaround. Test
them. If unrelated controls disappear or stop working, record **FAILED** for
isolation and stop. Do not reinterpret the user's acceptance criteria or quietly
permit those effects. Investigate a different mechanism or a reliably validated
solution before reconsidering full development.

## Build and permission handoff

```sh
cd /Users/james/Code/JimmyTweaks
bash Experiments/IconAbsorberPoC/build.sh
open "Experiments/IconAbsorberPoC/build/Icon Absorber Probe.app"
```

This uses only the installed SDK and compiler. It does not download dependencies,
alter third-party preferences, register startup services, or request Screen Recording.

1. In **System Settings → Privacy & Security → Accessibility**, add/enable
   `Icon Absorber Probe.app` from the path above. This allows the probe to inspect
   and control other applications. The developer must not silently grant it.
2. Quit the probe with Command-Q and reopen it. Check its startup log for
   `Accessibility trusted: true` and `Input posting permitted: true`. Rebuilding
   an ad-hoc signed app may require renewing its permission entry.
3. Ensure MonitorControl is running and its icon is actually visible. LinearMouse
   is installed too; keep it available for the additional test. The probe does
   not launch either application automatically.
4. Choose **Discover**. If either permission remains false or discovery returns
   an error, stop and preserve the exact log. Do not infer that the mechanism works.

For a durable timestamped event log, quit the GUI copy first, then launch its
executable from Terminal (same bundle/executable identity):

```sh
"Experiments/IconAbsorberPoC/build/Icon Absorber Probe.app/Contents/MacOS/IconAbsorberProbe" \
  2>&1 | tee Experiments/IconAbsorberPoC/Evidence/manual-session.txt
```

Read-only diagnostics can also be collected with the executable's `--diagnose`
argument. A diagnostic run exits successfully even when permissions are missing;
its exit code is not a test verdict. The restricted agent environment returned
zero running apps; the real desktop launch returned 96. Only desktop-session
observations are relevant to the runtime tests.

## Mandatory real test procedure

Use an ordinary desktop with the menu bar visible. Record display count,
auto-hide/notch/overflow state, application versions, current PID, icon location,
and the visible unrelated controls before changing anything. If an icon already
overflows, make room manually first. The probe will not hide more applications to
make room or drag third-party icons. Screenshots/video are useful supporting
evidence; source logs alone cannot establish visibility or usability.

1. **Discovery:** Select MonitorControl's discovered item. Save its bundle ID,
   PID, item index/identifier, label, bounds and supported actions. Multiple items
   appear separately, but hiding applies to the whole bundle.
2. **Hiding:** Choose **Hide selected app (60 s)**. Visually confirm the icon
   disappears and its space is reclaimed. Confirm MonitorControl's original PID
   remains alive. An `ASSERTION ACCEPTED` label only reports API completion.
3. **Invocation:** While hidden, choose **Simulated left click**. The restriction
   is released, the item is rediscovered with stable bounds, and a mouse down/up
   pair is sent only if the hit-test owner matches the target. Confirm the actual
   MonitorControl brightness interface opens. Move a brightness slider slightly,
   verify the real display response, and restore its original value. Close the UI,
   re-hide, and repeat using **Simulated right click**. Record the original app's
   supported right-click behavior, including a no-op if that is its baseline.
   **Original AXPress** is a separate diagnostic path; success there does not
   substitute for missing synthesized-click evidence. If hit testing refuses the
   event because MenuBarAgent owns the hit, record that limitation and investigate
   dispatch; do not click stale coordinates or claim the click passed.
4. **Restoration:** Close the original UI, re-hide, then choose **Restore All**.
   Confirm the icon's visibility and previous ordering return with the same owner
   PID and working controls. Compare with the baseline.
5. **Crash recovery:** Re-hide and visually confirm before the timer expires.
   Choose **Crash while hidden**. This sends SIGKILL to the probe without running
   its invalidation/shutdown code. Do not reopen it or restart MonitorControl.
   Confirm the icon returns promptly, retains its placement and still works.
   Record the elapsed recovery time and unchanged owner PID. If it does not return,
   mark FAILED and preserve evidence before any manual recovery.
6. **Isolation:** In a separate hide session, operate Control Center, Wi-Fi,
   volume, clock/Notification Center and other controls present in the baseline,
   including Focus/Fast User Switching if visible. Check unrelated third-party
   items too. Close each surface before the next. Verify both appearance and
   behavior. Do not count tests after the 60-second auto-release as tests under an
   active assertion. Missing/disabled unrelated controls fail the requirement.
7. Repeat with LinearMouse, documenting its own original left/right behavior.
   MonitorControl's real brightness UI remains the primary required test.

Invocation intentionally stays restored until the tester closes the original UI
and explicitly re-hides. Automatic popup-close tracking, relocation, icon capture,
wallpaper preview, persistence and production integration are later-phase work.
No third-party menu or slider is mocked. No watcher process restores icons.

Restore All and normal quit invalidate the assertion. A 60-second timer releases
pending/active assertions. Running-application changes and session sleep/inactivity
also release it so a newly launched unselected app is not silently excluded. These
guards are useful controls; they are not evidence of system-managed crash recovery.

## Recorded acceptance results

See [desktop-session.txt](Evidence/desktop-session.txt) and
[diagnostics-restricted.txt](Evidence/diagnostics-restricted.txt).

| Requirement | Result on 2026-10-30 | Evidence / blocker |
| --- | --- | --- |
| Build and signature | Completed | Swift/ObjC build exit 0; strict codesign verification passed; shell syntax check passed |
| Framework capability | Present, behavior unverified | `dlopen` and expected runtime signatures matched |
| Test apps running | Observed | MonitorControl 4.4.0 PID 8359, LinearMouse 0.12.0 PID 959 in desktop probe |
| Status-item discovery | Completed after permission grant | Both reads returned AX error 0; original AX items, bounds and AXPress actions obtained |
| MonitorControl remains running while hidden | UNVERIFIED | Assertion accepted; owner registered; guard released after one second before visual verification |
| Real brightness UI and left/right invocation | UNVERIFIED | Left mouse pair posted after release; original UI usability unverified; right-click not executed |
| Icon restoration and prior placement | UNVERIFIED | Invalidation called; actual visibility/order not visually verified |
| Icon returns after SIGKILL | UNVERIFIED | Crash test not executed |
| Unrelated controls remain usable | UNVERIFIED | Active-restriction test not executed; source documents a material risk |

The build emitted two `sandbox-exec: sandbox_apply: Operation not permitted`
diagnostics, but compilation/signing completed and the desktop app launched.
There was no automatic approval-review rejection. Privacy authorization was the
initial blocker and has since been granted. Visual/functional verification and
the overly broad running-application-change release guard remain outstanding.

**Final Phase 1 status: UNVERIFIED.** No production module, design preview,
integration, feature commit or feature PR has been made. After permission is
granted (now completed), complete every mandatory row with observed behavior. Any mandatory
functional failure means FAILED. Only complete success, including isolation,
permits changing the status to PASSED and beginning Phase 2.
