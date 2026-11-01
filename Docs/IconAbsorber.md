# Icon Absorber

## Verification status and authorization

**The original proof of concept remains UNVERIFIED.** The user reported that hiding
and the restored AXPress path worked, then explicitly instructed: “assume everything
works, go ahead and implement this new module.” Integration proceeds under that
updated instruction. It is not a claim that crash recovery, isolation, hidden
AXPress, slider usability, or all other original acceptance criteria passed.

The separate experiment and its original observations remain in
[`Experiments/IconAbsorberPoC`](../Experiments/IconAbsorberPoC/README.md).
No mock third-party menu, slider, or fabricated success message is shipped.

## Native interface and preferences

The new Settings sidebar page includes a shallow desktop slice with straight top
and right boundaries and restrained irregular left and bottom continuation edges.
It loads the active screen's wallpaper using `NSWorkspace.desktopImageURL(for:)`,
draws a crop of its upper-right region, and shows only the selected applications'
status items. It follows the screen containing Settings. Space/display changes,
appearance changes, and a five-second visible-page refresh update the wallpaper.
Dynamic/video wallpapers may provide only a still image or no readable asset.
Unavailable wallpaper is explicitly labeled and uses a neutral background.

Selections are whole bundle identifiers. A separate Foundation model preserves
application order without depending on AX element identities or preview layout.
Selection and ordering persist through the existing PreferenceStore/UserDefaults
domain. Each running app can contribute several individual preview icons.
Stopped selected applications stay in the management list. All module preferences
are off by default except best-effort floating-panel positioning. Reset Window
Resizer preserves this module; Reset All also clears its selection.

Drag selected rows, or use Move Earlier/Later, to reorder applications. Preview
icons retain relative native item widths and scroll horizontally if necessary.
Left-click and right-click invoke the original application. Actual status-item
pictures are optional: Refresh Icon Pictures requires existing Screen Recording
permission, temporarily restores selected items, then captures only the
MenuBarAgent window using ScreenCaptureKit. It rejects unstable, overlapping, or
empty crops, caches the images only in memory, and reapplies the selection.
Pictures are refreshed explicitly rather than continuously recording the bar.
Without pictures, recognizable application icons are used and labeled as such.

## Isolation and lifecycle

`IconAbsorberController` is independent of the window gesture engine. It shares
only the established preference, permission, logging and Settings context.
Accessibility discovery runs on a separate worker, excludes Jimmy Tweaks' own
process, and uses bounded per-process AX timeouts. Running-app KVO and supported
AX notifications trigger updates. A fifteen-second fallback handles apps that
do not publish status-item creation notifications; it stops when neither the
module nor its page is in use. Wallpaper refresh stops when the page is hidden.

The main UI process never loads `MenuBarClientCore`. The bundled
`Contents/Helpers/IconAbsorberAgent` executable alone loads it and owns
`MBAssessmentModeAssertion`. The Objective-C adapter checks the installed OS
major version (27), class availability and method signatures. No entitlements are
added. Unexpected native faults are confined to that process. Requests and
responses use bounded newline-delimited JSON over inherited pipes, with startup
and response timeouts. Invalid input or a rejected API stops/relinquishes the
service. There is no automatic service crash-restart loop.
The parent pipe uses nonblocking writes and descriptor-local SIGPIPE suppression,
so a dead or stalled service cannot block or signal-kill the UI process.

The helper admits all currently running bundles except selected ones, and the
nine reverse-engineered system item identifiers. Its own running-app KVO handles
agent applications that omit launch notifications. A parent crash closes the
pipe; EOF exits the holder. The holder's process/connection death is the expected
system-managed assertion cleanup mechanism. No external watchdog or permanent
third-party preference change is used. Actual restoration after a hidden-process
crash remains a manual acceptance test, not something inferred from this design.

Disable, Restore All, Suspend All, sleep, inactive sessions, permission denial,
service failure and normal shutdown all stop the holder. Settings may close while
enabled absorption continues. Failure leaves Window Resizer/Window Mover running
independently. Missing helper binaries report an error with restoration rather
than affecting unrelated features. Command-line and Xcode builds both bundle and
sign the helper; distribution re-signs it before signing the enclosing app.

## Original controls and positioning

The default path temporarily releases hiding for the chosen application, waits
for freshly discovered stable geometry, and invokes its original AXPress action.
It does not synthesize a global left click or warp the pointer. Menu-close
notifications and temporary surface monitoring reapply hiding after the original
controls close. The optional hidden-AXPress path uses the cached original AX
element while keeping the assertion; it has no silent reveal fallback.

Right-click uses AXShowMenu when exposed, otherwise a target-process mouse event
pair after validating the actual hit-test owner. It does not use global HID
posting. Acceptance and behavior depend on the target and are not established by
an event-posting return value.

Only new, nonmodal Accessibility floating windows with a settable position and
reasonable bounds are candidates for best-effort repositioning. Each write checks
that the interaction is still current. Native menus, protected/inaccessible
surfaces and standard app windows are left in their original locations. There
is no reconstruction, private menu relocation, focus raising, or drag simulation.

Opening controls is monitored for up to two minutes. If they remain open beyond
that, the module restores all items and pauses until Refresh, instead of tearing
down the owner's long-lived interface. The clock interaction temporarily lifts
the assertion so Notification Center can open. That workaround also requires
runtime validation on the supported OS.

## Compatibility limits

This private API can change or disappear in any update. Only macOS major version
27 is enabled; other versions fail safely while the rest of Jimmy Tweaks remains
usable. Presence/signature checks establish capability, not behavioral support.

The assertion cannot promise to preserve Apple modules beyond its nine supported
system-item values. Before restricting anything, the controller checks the
discovered MenuBarAgent system items. If unsupported controls are present it
enters **Compatibility Pause** and restores everything. This can include
audio/video privacy controls exposed during conferencing or computer use.
Unknown controls are not silently suppressed to make absorption appear viable.
Changes that lack supported notifications are noticed by the fallback scan.

Hidden items may keep stale AX frames, change identities, fail to publish AX
events, or expose no supported secondary action. Geometry alone is never evidence
that an item is visible. Picturing some icons may fail; stale or missing pictures
fall back to application icons. A full menu bar/notch/overflow can prevent
restored activation without rearranging or hiding additional applications; that
case fails safely and suggests Refresh.

## Checks completed on 2026-10-31

Environment: Apple silicon, macOS 27.0.1 build 26A434, Swift 6.4/macOS 27 SDK.

- Development, Release and Xcode Development builds completed, with signed helper.
  Development and Release bundles passed strict code-signature verification.
- Existing 2,178 core checks, window-engine regressions, source boundary checks,
  and the eight-page native Settings UI smoke test passed.
- Fourteen focused module checks passed: identity filtering, ordering, persistence,
  reset boundaries, permission denial, Restore All and missing-helper isolation.
- Real helper protocol checks passed for clear/EOF, malformed JSON, refusal to
  accept Apple bundle selections, and bounded input. These requests hid no apps.
- A real client/service test passed for clear acknowledgement and the race between
  SIGKILL of the service and writing the next request. The host survived and
  reported failure; no hidden-item crash recovery is inferred from this test.
- Your latest glow-indicator implementation was merged and remains unchanged
  relative to `main`.

Restricted/headless runs emit LaunchServices/XPC diagnostics. They do not establish
live behavior. Headless bitmap output is not reliable wallpaper/desktop evidence.
Native app lookup did not launch this agent in the desktop session; attempts to
use Finder also encountered changing UI state. No successful restart or live
end-to-end test of the new integrated module is claimed.

### Remaining manual acceptance

Build/open the app, grant its own Accessibility permission if needed, then:

1. Select MonitorControl and LinearMouse; enable, disable, Suspend All, restore,
   close/reopen Settings, and restart the app. Check selections/order persist.
2. Confirm real hiding, original brightness controls, unchanged owner PID,
   left/right behavior and automatic re-hiding after the controls close.
3. Test the hidden-AXPress option separately. Verify icon visibility and actual
   slider/display response; an AX success code is insufficient.
4. With an item hidden, force-quit Jimmy Tweaks. Verify the icon returns without
   restarting its owner. Separately kill the visibility holder and confirm the
   parent/window controls continue running and report the service fault.
5. Operate all unrelated/system controls while restricting. Confirm unsupported
   controls cause restoration/Compatibility Pause and validate clock access.
6. Check your actual wallpaper, display/Space changes, optional icon pictures,
   multiple status items, app restarts and unavailable/revoked permissions.

Record each observed result independently. The original proof of concept is not
retroactively marked PASSED by any build, smoke test, or user waiver.
