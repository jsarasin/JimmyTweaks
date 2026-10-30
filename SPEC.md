# Jimmy Tweaks — Implementation Specification

Version: 1.0  
Specification date: October 29, 2026  
Minimum operating system: macOS 27.0  
Deliverable: a native Swift/AppKit utility; this document contains requirements, not application implementation.

## 1. Authority and product contract

Jimmy Tweaks is a hidden, single-process macOS agent that provides system-wide window resizing and moving, with one native Settings window. Its second utility, **Reoccurring Scripts**, is strictly a **NONFUNCTIONAL UI STUB**.

This specification consolidates the current request and the finalized decisions retrievable from the referenced “macOS Window Resizing Utility” conversation. The retrieved conversation ends with the confirmed architectural choices and independent configurable moving threshold. The current request supplies the remaining binding scope. Details not expressly fixed by those sources are resolved here, especially in §16; they are implementation decisions, not claims about inaccessible earlier messages.

**MUST** indicates an acceptance requirement. **SHOULD** indicates an implementation preference whose deviation needs a documented reason. Requirements apply to the initial deliverable unless explicitly described as a platform constraint.

The implementation MUST deliver:

- Swift, pure AppKit, programmatic Auto Layout, one application bundle, one executable, and one application process per logged-in user session.
- A monolithic codebase with concrete internal responsibilities and no extensibility framework.
- Background operation after Settings closes; reopening the application opens the existing Settings window or creates it if necessary.
- Prominent Status, persistent master suspension, individual utility preferences, immediate settings application, and both application-wide and per-utility preference resets.
- A first-run, guided, skippable permission assistant that can be reopened later.
- Command + right-button corner resizing, with Immediate activation by default and an adjustable threshold alternative.
- Command + left-button interior moving, enabled by default, with its own adjustable 5-point threshold.
- Plain-text normal logging retained for seven days, local UserDefaults preferences, optional Release-only launch at login, and direct Developer ID distribution with notarization.
- A clearly labeled scripts preview with compact sample URL scripts, UI-only editing controls, and fictional sample history. It MUST have no scheduler, interpreter, script execution, URL fetching, or real run history.

No other functional utilities are part of this version. There is no menu-bar status item and no global shortcut for opening Settings. Runtime operation requires no account, network connection, analytics, or telemetry.

## 2. Platform and application structure

### 2.1 Technology

Use Swift and the stable Xcode toolchain supporting the macOS 27 SDK. Set the deployment target to 27.0. Support Apple silicon; additional architectures are required only if macOS 27 and the selected toolchain officially support them and they are included in the tested distribution. Do not claim support for untested architectures or earlier operating systems.

Use AppKit for every user interface, including Settings, permission guidance, tables, dialogs, overlays, and feedback. Do not use SwiftUI, embedded web interfaces, or cross-platform interface frameworks. Prefer system controls, system fonts, semantic colors, and SF Symbols where available.

The app runs as the current user, with `LSUIElement = YES`, outside App Sandbox, using Hardened Runtime. It MUST NOT require administrator privileges, install a privileged component, or start a separate application-owned background executable.

Use public frameworks: AppKit/Foundation, ApplicationServices Accessibility APIs, Core Graphics event services, and ServiceManagement for the login preference. Public OS services do not change the single application-process requirement. No private window-management APIs are permitted.

### 2.2 Concrete internal responsibilities

These are ordinary concrete types/files within the application target, not independently deployable components. Do not create a generic utility framework merely to represent these responsibilities.

| Responsibility | Owns |
| --- | --- |
| Application coordinator | Startup, reopen, one Settings window, explicit quit, lifecycle shutdown |
| Preference store | Typed defaults, validation, schema migration, change delivery, resets |
| Runtime coordinator | Effective enablement, suspension, utility health, bounded recovery |
| Permission coordinator | Trust/capability checks, user-initiated requests, assistant progress |
| Window gesture controller | One event tap, gesture state, event ownership, physical-button tracking |
| Accessibility window controller | Hit testing, target validation, frame reads/writes, geometry reconciliation |
| Feedback controller | Optional cursor and nonactivating overlay lifetime |
| Settings controllers | Split view, navigation table, page content, native search results |
| Search metadata catalog | Stable control identifiers, descriptive metadata, destinations |
| File logger | Serialized append, rotation, retention, opening current log |
| Scripts preview model | In-memory demonstration rows and sample history only |

AppKit mutations MUST run on the main thread. Event interception MUST run on its own run-loop thread. Cross-process Accessibility work MUST run on a separate serial worker; it MUST NOT block the event callback or main thread. Logging uses a serial background writer. Share immutable preference/runtime snapshots with the event thread, and serialize gesture transitions on that thread.

Each gesture and each activation of the window engine has a generation identifier. Results arriving after cancellation, suspension, target replacement, or engine shutdown MUST be discarded. Recheck that identifier and the admission/termination gate before every AX write, including corrective writes; finishing an already-started call never authorizes the next call in its transaction. Escape restoration gets a distinct, bounded restoration generation that is also invalidated by suspension, permission loss, or target destruction. Only one geometry write transaction may be in flight; coalesce pending pointer positions to the newest value.

## 3. Lifecycle, activation, and suspension

### 3.1 Launch and reopen behavior

| Entry condition | Required result |
| --- | --- |
| First deliberate application open | Show Settings on Status and present the permission assistant as a sheet |
| Later deliberate open while process is absent | Start eligible background features; show Settings on Status |
| Reopen while already running | Bring the single existing Settings window forward, retaining its current page; create it on Status if closed |
| Launch at login | Start silently, honor saved suspension and utility preferences, and show no assistant or permission prompts |
| First-ever startup happens at login | Remain silent; defer first-run guidance until deliberate open |
| Close Settings or its final window | Keep the agent running, even if every utility is disabled or suspended |
| Quit Jimmy Tweaks | Finish shutdown and terminate the application process |

Use Launch Services/AppKit reopen handling and the public open-application launch-event information to distinguish login startup from deliberate open. In particular, inspect the login-item information in `kAEOpenApplication`/`keyAEPropData`; do not infer login startup from whether a window happens to be visible. See [Apple’s launch-event constants](https://developer.apple.com/documentation/coreservices/apple_events/1556410-launch_apple_event_constants).

Opening multiple copies of the same installed app MUST route normal open requests to the existing instance. Do not add a hand-built cross-process control service. Document duplicate independently installed bundles as unsupported; distribution validation covers normal reopening of the same installed bundle.

Provide an explicit **Quit Jimmy Tweaks** action in the persistent Settings footer and a standard application Quit command while Settings is active. Closing a window MUST NOT imply quit. Quitting does not unregister a previously enabled login item; the login preference explains this.

### 3.2 Persistent Suspend All

An always-visible native toggle labeled **Suspend All** belongs to Settings window chrome, outside the page scroll area and search results. It MUST remain reachable on every page, during search, and when another page has an error. Its value persists across closing Settings, quitting, and subsequent launches, including login startup.

When enabled:

1. Persist the new value and close the gesture admission gate immediately.
2. End any active manipulation at the last accepted frame; do not roll it back.
3. Resolve a pending unclaimed gesture using §9, remove feedback, and stop admitting new operations.
4. Drain an already-owned physical button sequence safely, then remove the event tap when no owned sequence remains. Ordinary input is never disabled.
5. Preserve every per-utility and per-gesture preference.

One Accessibility request already executing may complete within its configured timeout. No subsequent frame transaction may start. Status must not imply that an in-flight external request can be recalled.

When suspension is turned off, automatically start eligible enabled features. Missing permission and exhausted failure states remain visible. Turning suspension off MUST NOT erase a Failed state or create an unlimited retry loop; use **Retry** for an exhausted failure.

Settings navigation, preference editing, permission guidance, log access, resets, and scripts preview editing remain available while suspended.

### 3.3 Utility state and recovery

Represent configured intent separately from effective runtime state. A saved enabled preference is never changed merely because permission is missing or a start attempt fails.

Window Resizer has one utility enable preference and separate Resize Windows and Move Windows switches. The event engine runs if the utility is enabled, at least one gesture is enabled, suspension is off, the user session is active, permissions are sufficient, and engine health permits it.

| Effective state | Meaning and action |
| --- | --- |
| Disabled | Utility preference off, or both gestures off; show the precise reason |
| Suspended | Suspend All is on; preserve intent and show any underlying permission/failure detail |
| Paused — Session Inactive | Screen locked, session switched away, or system asleep; resume automatically after revalidation |
| Permission Required | A required capability is unavailable; offer guidance, no repeated prompting |
| Starting | Engine startup or bounded recovery is in progress |
| Running | Event engine operational; gesture-specific availability also shown |
| Failed | Engine retries exhausted; expose reason, last failure time, Retry, and Open Log File |
| UI Stub | Scripts preview only; never report Running or waiting for a scheduled run |

For app-owned engine faults, allow one initial attempt and up to three retries after 1, 2, and 4 seconds. Cap recoveries at three within any rolling 60-second interval, including event-tap disablement recovery. After exhaustion mark Failed and stop. A successful uninterrupted 60 seconds clears the burst counter. A deliberate Retry, or disabling then enabling the utility, begins a new user-requested attempt cycle.

Permission denial, unsupported target windows, and target-app-specific Accessibility failures are not engine failures. Do not retry a denied permission automatically. An event tap disabled because the user or system has removed access must transition to Permission Required or Paused, as appropriate, rather than fighting the system. Recheck eligibility before every retry. The scripts stub has no retry mechanism.

## 4. Settings interface

### 4.1 Window and navigation

Create exactly one resizable Settings `NSWindow`, initially approximately 960 × 700 points, minimum 780 × 560 points. Save the window frame using standard AppKit frame autosaving; repair a saved frame that lies entirely off the current displays. Support standard keyboard navigation, resizing, scrolling, light/dark appearance, increased contrast, and Reduce Motion.

The root content controller MUST be `NSSplitViewController`. The left sidebar MUST use a view-based `NSTableView` with native selection and group rows. The detail pane uses concrete AppKit view controllers and programmatic Auto Layout. Tables for search results, script rows, and sample history MUST also be native `NSTableView` instances. See [NSSplitViewController](https://developer.apple.com/documentation/appkit/nssplitviewcontroller) and [NSTableView](https://developer.apple.com/documentation/appkit/nstableview).

Sidebar order:

1. **Status** — pinned first and visually prominent.
2. **Utilities** — nonselectable group label.
3. **Window Resizer**.
4. **Reoccurring Scripts** — visible “UI Stub” badge.
5. **Application** — nonselectable group label.
6. **General**.
7. **Permissions**.
8. **Logging**.
9. **About**.

Keep a search field visible at the top of the sidebar, Suspend All visible above the split content, and Quit Jimmy Tweaks in a persistent footer. Status and suspension state must be understandable without opening a disclosure group. A suspended-state banner also offers **Resume All**, which changes the same master preference.

All valid preferences apply immediately; there is no Apply or Save button. Numeric field editing commits on Return, focus exit, or a paired stepper action. Invalid text stays visible with an inline error and does not change the saved value. Disabling a parent control preserves its child values and shows why those controls are unavailable. Turning a feature off ends its active gesture as in §9; other edits are snapshotted for the next gesture.

### 4.2 Prominent Status page

Display, in this order:

- A large overall state summary and the current Suspend All state.
- This explanatory copy: **“Jimmy Tweaks runs in the background. Closing Settings does not stop enabled features. To change settings, open Jimmy Tweaks again from Applications.”**
- Window Resizer state, configured utility switch, individual resizing/moving states, and any blocking permission or failure.
- Reoccurring Scripts with **“NONFUNCTIONAL UI STUB — examples only; nothing runs.”** Do not give it a functional runtime switch here.
- Permission summary with **Open Permission Assistant** and **Review Permissions** actions.
- Failed-feature recovery actions, when applicable.
- **Open Log File** and links to the applicable Settings pages.

A fully running utility can still have one gesture disabled. Show “Running — resizing only” or “Running — moving only” as appropriate. If both are disabled, show “Disabled — both gestures off.” Overall state MUST NOT count the scripts stub as a working or failed background utility.

### 4.3 Other pages

| Page | Required content |
| --- | --- |
| Window Resizer | Utility switch; Resize Windows section; Window Moving section; feedback options; gesture explanations; current capability state; Reset Window Resizer |
| Reoccurring Scripts | Permanent stub banner; compact sample list; selected sample detail; UI-only controls; Sample Run History; Reset Scripts Preview |
| General | Release-only Launch at Login preference; background/reopen explanation; Reset All Preferences |
| Permissions | Current permission/capability states; why each is needed; Open System Settings; Check Again; Open Permission Assistant |
| Logging | Fixed Normal logging and seven-day retention explanation; current file path; Open Log File; Reveal Logs Folder; I/O error state |
| About | Jimmy Tweaks name, app version/build, minimum supported macOS, concise feature description, local-only operation statement |

Do not add runtime modes or environment management to these pages. General is the home for the single compile-time-gated login preference, not a build-management interface.

## 5. Searchable per-control metadata

### 5.1 Catalog contract

Every user-facing preference and actionable control MUST have metadata, including page links, transient assistant buttons, search controls, reset actions, script preview fields, and persistent chrome actions. Read-only status groups and table destinations also need entries so users can discover their explanations.

Each entry contains:

| Field | Requirement |
| --- | --- |
| Stable ID | Unique, nonlocalized identifier, independent of the visible label |
| Label | Localized visible control or destination name |
| Description | Plain-language explanation of effect, limits, or stub behavior |
| Keywords | Synonyms, abbreviations, alternative spellings, gesture terms |
| Destination | Page ID, section ID, and control/focus ID; presentation action for transient UI |
| Breadcrumb | For example, Window Resizer › Window Moving › Drag Threshold |
| Availability | Enabled/disabled/conditional, with explanation; dynamically evaluated |
| Value summary | Safe human-readable current value where meaningful |

Stable IDs may share a destination when multiple discoverability terms describe one control. User-entered script content, arbitrary URL values, window titles, and logs MUST NOT be incorporated into the global Settings index. Catalog the script fields and fixed sample titles; local table selection is separate from global Settings search.

### 5.2 Matching and result behavior

- Use `NSSearchField`, with a 100 ms debounce; target updated results within 150 ms after the debounce for the entire local catalog.
- Trim leading/trailing whitespace; normalize case and diacritics. An empty/whitespace query restores normal detail content and the preceding page/scroll position.
- Split nonempty queries on whitespace. Every token must match at least one metadata field in an entry; tokens may match different fields. Match substrings; do not add fuzzy matching or remote search.
- Rank exact label matches first, label prefixes second, remaining label matches third, descriptions fourth, and keywords/breadcrumbs fifth; resolve ties by sidebar order, section order, then label. Use the weakest matching token to determine a multi-token entry's tier.
- Present results in a native table in the detail pane, keeping the sidebar, search field, Status navigation, and Suspend All visible. Each row shows label, breadcrumb, a concise description, and unavailable/stub state when relevant.
- Up/Down selects results while search is focused. Return opens the selected result; if none is selected, select and open the first result. Clicking a result does the same. Tab can move into the results table.
- Opening a result clears the query, navigates to its page, expands the destination section, scrolls the control into view, gives it keyboard focus when appropriate, and highlights it for about 1.5 seconds. Use a static outline when Reduce Motion is enabled.
- Navigation never activates the destination action or changes a preference. Searching “reset” must never reset anything. Searching for assistant controls opens the assistant and focuses the appropriate step/control without requesting permission automatically.
- For a disabled control, focus its containing group/help if the control cannot accept focus; show the disabling reason. Keep disabled preferences searchable. Controls absent from the compiled app, including the unavailable login preference, are absent from the index.
- Escape while searching clears the search and restores the previous page; it never changes suspension.

With zero results show **“No settings found for ‘{query}’.”**, followed by **“Try a feature name, gesture, or permission.”** and **Clear Search**. Escape and Clear Search return to the previous page. Announce the result count and empty state to VoiceOver without moving focus on every keystroke.

### 5.3 Minimum metadata inventory

The following IDs define the minimum catalog; §10 and §13 give their full behavior. Add entries for any further controls introduced in implementation.

| ID or ID family | Destination / representative keywords |
| --- | --- |
| `global.search`, `global.search.clear` | Search / find, filter, no results |
| `global.suspendAll`, `global.resumeAll`, `global.quit` | Persistent controls / pause, stop, resume, exit |
| `navigation.{pageID}` | Every selectable sidebar destination |
| `status.background`, `status.windowState`, `status.scriptsState` | Status / hidden, running, failed, examples |
| `status.retryWindowEngine`, `status.openAssistant`, `status.reviewPermissions`, `status.openLog` | Status actions |
| `window.enabled`, `window.resize.enabled`, `window.resize.activation`, `window.resize.threshold`, `window.resize.cornerSize` | Resizing / Command, cmd, right click, corner, immediate, small drag |
| `window.move.enabled`, `window.move.threshold` | Moving / Command, left drag, interior, five points |
| `window.feedback.cursor`, `window.feedback.cornerHints`, `window.feedback.frame`, `window.reset` | Feedback / pointer, overlay, outline, reset |
| `general.launchAtLogin`, `general.resetAll` | General / startup, sign in, defaults |
| `permissions.{capability}.status`, `.request`, `.openSettings`, `permissions.checkAgain`, `permissions.assistant` | Permissions / access, trust, monitoring, setup |
| `assistant.{stepID}.{actionID}` | Appropriate assistant step / back, next, skip, grant, check, finish |
| `logging.status`, `logging.retention`, `logging.path`, `logging.open`, `logging.reveal` | Logging / normal, seven days, plain text, logfile |
| `scripts.previewEnabled`, `.list`, `.add`, `.duplicate`, `.remove`, `.name`, `.url`, `.interval`, `.runPreview`, `.history`, `.clearHistory`, `.reset` | Scripts / recurring, reoccurring, schedule, URL, example, simulated |
| `scripts.row.{previewID}.enabled` | Per-row Enabled in Preview control; fixed seed IDs or unique in-memory preview IDs |
| `reset.{scope}.confirm`, `reset.{scope}.cancel` | Corresponding reset dialog; discover through its parent reset destination without confirming |
| `about.version`, `about.platform` | About / version, build, macOS |

Use `reoccurring` in the utility's visible name exactly as requested and index both “reoccurring” and “recurring.” Buttons duplicated across pages may have distinct control IDs but MUST bind to the same underlying action/preference.

## 6. Permission assistant and monitoring

### 6.1 Permission policy

Accessibility trust is required for cross-application frame manipulation and the active filtering event tap. Check it without prompting at launch and during ordinary monitoring. Request system permission only following an explicit user action in the assistant or Permissions page.

Use a modifying session event tap rather than a passive global monitor because gesture ownership requires suppressing selected mouse events. Apple's documented security distinction assigns modifying event taps to Accessibility authorization and passive listening to Input Monitoring. **Do not blindly require both permissions.** See [Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/).

Show Input Monitoring as **Not required for this capture path** unless validation on a supported macOS version establishes that the selected public path additionally needs it. If it does, provide the corresponding user-initiated request/guidance and treat it as a real blocker. A failed tap alone is insufficient evidence that Input Monitoring is missing: distinguish trust, session availability, tap creation errors, and OS policy using documented capability checks. Do not fabricate a definitive diagnosis.

No permission is requested for the scripts stub. This release has no need to request screen capture, Apple Events automation of other apps, filesystem-wide access, or notifications. Receiving the application's own launch event is not automation of another application.

Use OS-visible permission category names appropriate to the supported version/localization. “Accessibility” in this document names the API capability; explanatory copy must not rely on one permanently fixed System Settings label or pane URL. System Settings deep links are best effort; always provide a textual Privacy & Security navigation fallback. Permission grants remain user actions in System Settings.

### 6.2 Guided flow

Present a native sheet on the single Settings window, with a visible step title and progress indicator. It is modeless with respect to background operation but follows normal sheet interaction rules. Repeated launch requests bring forward the same assistant; they do not create another one.

| Step | Required content and actions |
| --- | --- |
| Welcome | Explain background operation, reopen through Applications, gestures, and why permission is needed; Next and Skip Setup |
| Accessibility | Live status; concise explanation; Enable Accessibility / Open System Settings; Check Again; Back, Next, Skip Setup |
| Additional capture access, only if required | Explain the actual additional capability; request/open-settings actions; live status; Back, Next, Skip Setup |
| Review | Show configured resizing/moving, suspension state, permission readiness, and scripts stub label; Finish, Back, Skip Setup |

A missing grant MUST NOT trap users in the assistant: Next and Finish remain possible and explain that affected features stay inactive. Skip Setup and closing the sheet save “skipped” state, dismiss the flow, and leave Settings usable. A completed or skipped assistant MUST NOT automatically reappear on every launch. **Open Permission Assistant** is always available from Status and Permissions; it rechecks actual grants and starts at the first unmet step, or Review if ready.

Do not store “granted” as a preference. Store only assistant version and completion/skipped state. When a grant becomes available, automatically activate enabled features if not suspended or in exhausted Failed state. Do not require an application restart unless the OS actually makes it necessary; if a valid grant still cannot be used, show a recoverable explanation and the manual quit/reopen route.

### 6.3 Rechecks and revocation

Recheck on application activation, return from System Settings, session resume, explicit Check Again, and relevant tap/Accessibility errors. Poll every two seconds while the assistant or Permissions page is visible, and every 30 seconds while the engine is eligible in the background. There is no background permission timer while all functional utilities are disabled or suspended; recheck before resume.

On revocation, close the admission gate, end any current operation at the last frame, clear feedback, drain event ownership where possible, and display Permission Required. Do not display repeated alerts or repeatedly reopen System Settings. System-enforced tap shutdown may prevent perfect draining; the cleanup constraints in §9 apply.

## 7. Window eligibility and hit testing

### 7.1 Target selection

The target is the topmost eligible visible window **under the initial mouse-down point**, whether active or inactive. Do not substitute the frontmost application's window, a window behind an unrelated surface, or another window when the pointer leaves the target during dragging.

Use `AXUIElementCopyElementAtPosition` and its owning-window relationship or a bounded parent walk, then validate the owning process and frame. Perform the initial system-wide hit test asynchronously on the main thread because a hit on our own process can synchronously invoke AppKit layout. Reject our own process before traversing attributes; resolve foreign elements and apply frame writes on the serial Accessibility worker. Bound ancestor traversal to 32 elements and detect cycles. Use the actual accessible window or independent sheet/panel element whose position and size are being changed, not an arbitrary child control. Cache hover results briefly, invalidate on relevant window/process/display changes, and revalidate at admission.

The scope includes standard windows, dialogs, sheets, and floating panels wherever public Accessibility attributes permit the requested operation. Eligibility is based on capabilities, not a standard-window-only whitelist:

- Frame attributes are readable and finite, with positive width and height.
- Resizing requires settable size **and position**, because all four corners must preserve their opposite corner.
- Moving requires settable position and a readable size.
- The element is visible, not minimized, not closing, and belongs to an available user application.
- Skip native full-screen windows, system-protected surfaces, menus, tooltips, popovers without an independently manipulable window, and elements whose target identity cannot be established safely.
- Skip Jimmy Tweaks' own Settings, assistant, alerts, and feedback windows to avoid stealing its controls.

Do not activate, focus, raise, or reorder the target. Do not use `AXRaise`, set focus/main-window attributes, or activate the owning application. Some apps may themselves activate in response to their own geometry changes; record this as an app compatibility limitation, not a reason to issue a compensating focus change.

There are no application-specific exclusions or special adapters in this version. Unsupported windows pass through normally. A target's inability to resize does not prevent moving if moving requirements are satisfied.

### 7.2 Corner and interior regions

All measurements are logical screen points. Default resize corner size is **200 points**, adjustable from **8 to 400 points** in whole-point increments. A corner region is a square extending inward from the window's outer Accessibility frame. Intersect it with the window frame. Cursor points on the window frame's boundary are eligible within a 0.5-point numerical tolerance; points outside the frame are not included by expanding the region.

Support top-left, top-right, bottom-left, and bottom-right. If corner squares overlap on a tiny window, choose the closest geometric corner; ties resolve top-left, top-right, bottom-left, bottom-right. Lock that corner when the gesture is admitted.

Moving requires the pointer to be at least **12 points inside every edge** and below the title-bar area. Determine the content area's top boundary from trustworthy Accessibility content/title-bar geometry where available; otherwise conservatively exclude the top **32 points** of the outer frame. The interior is the remaining rectangle, including ordinary content controls. An empty interior is ineligible. Command + left-drag in this region intentionally takes precedence over a control's ordinary drag after activation. A plain click retains ordinary behavior subject to §9.

Right-button resize eligibility is limited to corner regions. Right clicks elsewhere and left clicks outside the moving interior pass through. These distinct mouse buttons prevent ambiguity where an interior point also lies within a large resize corner square.

### 7.3 Input modifiers and buttons

The shortcuts are fixed: Command + physical/logical right-button events for resizing and Command + left-button events for moving. Either Command key qualifies. Trackpad secondary clicks qualify when macOS emits right-button events. Control-click does not substitute for right-click. Extra buttons do not qualify.

Command must be held at the initial down. Pressing Command after a button is already down MUST NOT capture that sequence. Additional Shift, Option, or Control modifiers at the initial down make the sequence ineligible; Caps Lock does not. Extra modifiers pressed during an active operation end it at the current frame. No aspect-ratio modifier or alternate shortcut is included.

## 8. Gesture geometry

### 8.1 Coordinates and timing

Use one normalized global coordinate system: logical points, origin at the primary display's top-left, positive x to the right and positive y downward. Pointer and Accessibility geometry MUST be normalized into this space before calculations. AppKit overlay conversion must account for its different origin convention. A single-desktop bounding-box flip is insufficient unless validated for the display arrangement.

Do not multiply drag thresholds by backing scale or divide already-point-based Accessibility values by it. Support fractional coordinates, negative display origins, different display scales, stacked displays, and a change in which display contains the cursor. Use `Double` precision for calculation and a 0.5-point equality tolerance. Round only where an API requires it.

Threshold activation uses Euclidean straight-line displacement from mouse-down, not accumulated path length: `distance = sqrt(dx² + dy²)`. Activate when distance is **greater than or equal to** the configured threshold. Once active, do not deactivate because the pointer moves back below it.

The first active geometry update includes the full displacement since mouse-down. The threshold is a dead zone for activation, not a permanent offset subtracted from motion. This can produce a first update of approximately the threshold distance; it does not recenter the window beneath the pointer.

### 8.2 Window resizing

Immediate mode claims an eligible Command + right-button down as soon as target validation succeeds, with no movement threshold. The first down alone need not change geometry. Dragging applies live resize updates. A click/release with no motion is consumed and does not show a context menu.

In **After Small Drag** mode, use an independent default threshold of **5 points**, adjustable from **1 to 30 points**, step 1. Preserve the stored threshold while Immediate is selected; disable its editor with an explanation that Immediate does not use it.

Capture the initial frame `(x0, y0, w0, h0)`, pointer `(p0x, p0y)`, selected corner, and opposite anchor. Let pointer displacement be `(dx, dy)`. Desired geometry before constraints is:

| Dragged corner | Opposite anchor | Desired width | Desired height | Desired origin |
| --- | --- | --- | --- | --- |
| Top-left | `(x0+w0, y0+h0)` | `w0-dx` | `h0-dy` | `(anchor.x-width, anchor.y-height)` |
| Top-right | `(x0, y0+h0)` | `w0+dx` | `h0-dy` | `(anchor.x, anchor.y-height)` |
| Bottom-left | `(x0+w0, y0)` | `w0-dx` | `h0+dy` | `(anchor.x-width, anchor.y)` |
| Bottom-right | `(x0, y0)` | `w0+dx` | `h0+dy` | `(anchor.x, anchor.y)` |

The opposite anchor MUST remain fixed on cooperative targets. The selected edge/corner keeps its initial cursor offset; snapping the corner directly to the pointer would create a jump and is prohibited. Do not flip to a different corner or create negative dimensions if the pointer crosses the anchor.

Clamp width and height to at least 1 point before submitting. Honor target-provided size restrictions if reliably exposed, and always honor the actual size returned by the target. Do not assume public Accessibility exposes a universal min/max-size API. Never invent one. The app's actual minimum, maximum, aspect ratio, resize increments, and system restrictions take precedence over desired size.

### 8.3 Applying and reconciling Accessibility frames

Use public `AXUIElementIsAttributeSettable`, `AXUIElementCopyAttributeValue`, and `AXUIElementSetAttributeValue` with `AXValue` point/size payloads. Attribute writes can fail or be constrained; see [attribute mutability](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable) and [attribute writes](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue).

For each resize transaction:

1. Set desired size, using the snapshot anchor to derive a desired origin.
2. Read the accepted size; recompute the origin from that accepted size and the same opposite anchor.
3. Set the recomputed position, then read back the resulting frame.
4. If the position write caused a further size change or the opposite anchor still differs, permit **one** additional corrective position write/readback. Do not iterate indefinitely.
5. Publish the actual accepted frame to overlays and diagnostics. Do not draw an unconstrained desired frame as if it were applied.

Separate AX position and size writes are not atomic; a transient intermediate frame may be visible. Steady-state anchor error on cooperative targets must be ≤1 point per axis after reconciliation. If macOS or the target constrains the accepted position or size, preserve the original target, corner, and pointer offset and keep the gesture active. Leaving the target window, crossing another window, or reaching a size/position limit MUST NOT end the gesture. Continue submitting geometry from the initial frame so reversing direction resumes control. Do not force the app to adopt unsupported geometry. Actual AX errors, target destruction, and explicit cancellation still end the gesture.

On an AX timeout/invalid-element error, end the gesture and stop writes to that target. On a successful write that returns unchanged geometry at a minimum/maximum boundary, do not treat it as a fault; continue accepting pointer movement so reversing direction can resize again. Compute future requests from the initial frame, not by accumulating rounded accepted deltas.

Coalesce pointer updates and target at most **60 frame transactions per second**, with at most one transaction running and one newest pending sample. Flush the latest eligible sample on ordinary completion; discard it on cancellation/suspension. Do not admit a new owned gesture until the previous gesture's final transaction/restoration has completed or been invalidated; a fresh down arriving during that short cleanup passes through. Use a 50 ms per-call Accessibility messaging timeout, setting the process-wide default through the system-wide AX element and any deliberate per-element overrides, and verify the return result. Do not assume setting an application element's timeout automatically applies to its child window objects. Do not wait on a worker from the event callback. A slow app may reduce achieved frame rate; responsiveness of input and Settings takes priority. See [Accessibility messaging timeouts](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).

### 8.4 Window moving

Moving is independently enabled by default. It always uses threshold activation; this version does not expose Immediate moving. Its threshold is **5 points** by default, adjustable from **1 to 30 points**, step 1, independent of the resize threshold.

Capture the initial pointer offset from the window origin: `(offsetX, offsetY) = pointer0 - origin0`. Each active update sets desired origin to `pointerNow - offset`, using the unchanged initial size. Do not resize, center, or snap the window. Use position-only AX writes and read back actual geometry. If the target itself changes size materially during moving, end the gesture instead of trying to force its old size.

The initial cursor offset stays constant while the target accepts requested positions. If macOS constrains movement, respect it; do not warp the mouse to compensate. Release Command or the initiating button to finish at the last accepted position.

### 8.5 Displays and window boundaries

Allow partially off-screen resizing and moving. Apply no application-imposed visible-frame clamp, snapping, tiling, or automatic rescue during a gesture. The pointer itself remains subject to the system's display bounds. Accept legitimate negative coordinates. Do not fight restrictions enforced by macOS or the target app.

If a display is added, removed, or rearranged during a gesture, finish at the last accepted frame, clear feedback, and require a fresh gesture using updated display transforms. Do the same on active Space change, screen lock, fast user switching, or sleep. Never transfer an in-progress gesture to another Space or target.

## 9. Event ownership, cancellation, and failure semantics

### 9.1 Event tap requirements

Use a session-level, active filtering `CGEvent` tap at a documented nonprivileged location, preferably head insertion. Do not use a HID-level tap requiring elevated privileges. Global `NSEvent` observation alone cannot provide the required suppression. See [event tap creation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)).

Observe left/right mouse down, drag and up, pointer motion needed for hints, modifier changes, tap-disabled signals, and keyboard events solely to recognize Escape and maintain a balanced Escape key pair when claimed. Do not decode, store, or log unrelated keyboard content. Forward unrelated key events immediately. Do not subscribe to scroll or extra-button events unless needed only to relinquish a pending sequence; they always retain normal behavior.

The callback's steady-state work MUST be bounded and allocation-light: read an immutable snapshot, update event state, enqueue work, and return the event or suppress it. No AX queries, disk access, permission prompts, AppKit calls, or synchronous worker waits. Aim for <1 ms typical and <2 ms p99 callback duration on the reference test machine.

### 9.2 State model

Only one manipulation may be owned at a time. States:

| State | Behavior |
| --- | --- |
| Idle | All unrelated events pass through; eligible down can start target resolution |
| Resolving | Provisionally hold the candidate down and that button's drag stream while the AX worker validates its target |
| Pending Threshold | Eligible target fixed; hold candidate sequence until threshold, release, or cancellation |
| Active Resize / Active Move | Consume initiating button sequence; schedule geometry updates |
| Draining | No more geometry updates; consume the remainder of an already-claimed sequence until its physical up |
| Pass Through Until Up | Candidate relinquished; forward the rest of that button sequence; do not recapture it |

Keep provisional target resolution bounded to **75 ms**. On a cache miss, query asynchronously; on deadline expiry, invalid target, uncertainty, or unavailable permissions, release the sequence normally and use Pass Through Until Up. Check deadline/generation between AX lookup calls; discard late results without starting additional lookup calls. A down/up completed before validation may be released normally, even in Immediate mode, to avoid delaying clicks. “Immediate” means no movement threshold after eligibility is established; it does not authorize blocking the tap on AX.

For an eligible threshold gesture, hold the initial down so the target app cannot begin its own drag. Keep only the original down and the newest coalesced subthreshold drag sample; memory must remain bounded during a long hold. On reaching the threshold, claim the sequence, discard the held ordinary mouse events, and begin manipulation. Do not send an ordinary down to the target first and then attempt to take it back.

### 9.3 Unclaimed click preservation and replay

If the button is released before activation, forward a balanced ordinary mouse sequence: original down, optional coalesced subthreshold drag, then up, in order, with captured coordinates, button identity, click count, flags, and coherent timestamps. If Command is released before activation, first release the held sequence so far, then pass the rest through. Do not manufacture an up while the physical button is still held just to simplify the state machine.

If an unrelated key, another mouse button, or an incompatible modifier arrives while provisional/pending, relinquish and release the candidate sequence **before** forwarding that new event. A lock/session-loss boundary or Escape instead discards an unclaimed candidate to avoid delivering a delayed click into a different context. Quitting follows the ordinary release path while the session is still valid; if it is no longer valid, discard it.

Use public event-posting APIs with copied events and a private application marker. Skip marked events in the interceptor to prevent recursion. Post replay through the tap proxy at the appropriate point when possible; otherwise use a single serialized posting path with explicit ordering and tagged events. Do not deliver replay directly to an arbitrarily chosen process. See [tapPostEvent](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent(_:)).

Ordinary Command-clicks and subthreshold gestures must retain their normal action wherever possible. Threshold mode necessarily delays delivery until activation is rejected or the button is released. Coalescing can change tiny drag paths; long-press timing, other tools' interception, rapid focus changes, and applications that reject synthetic input cannot be reproduced perfectly. State this limitation in help, and test Finder Command-selection and browser Command-clicks specifically. Do not promise bit-for-bit input transparency.

### 9.4 Claimed sequences and termination

After activation, consume the initiating down/drag/up sequence so the target does not receive a context menu, click, selection drag, or orphan up. If Command is released first, stop geometry and enter Draining until that button is physically released. Repressing Command before release MUST NOT resume or start a new operation. A second button or additional modifier ends the manipulation and drains the original owned button; unrelated input continues to pass through. Keep a separately owned Escape-key token until its matching physical key-up has been consumed, even if the mouse sequence finishes first; ignore auto-repeat Escape downs while that token is held.

| Event | Geometry result | Mouse/event result |
| --- | --- | --- |
| Initiating mouse-up while active | Apply newest eligible pointer sample, keep accepted frame, end | Consume the initiating up, complete owned sequence, and clear feedback |
| Command released while active | Keep last accepted frame; discard newer pending movement | Drain initiating button through up; pass modifier event |
| Escape while active | Cancel; attempt one bounded restoration to the original frame | Consume Escape down and matching up; drain initiating mouse button |
| Escape while pending/resolving | No frame change | Discard candidate; drain that physical button; consume Escape pair |
| Utility/gesture disabled, Suspend All, explicit quit | Keep last accepted frame | Stop admission; drain owned sequence where session access remains |
| Target closes, exits, becomes invalid, or permission disappears | Keep any frame already accepted; no writes to a replacement target | Remove feedback; drain if possible |
| Display/Space/session/sleep transition | Keep accepted frame; no rollback or target transfer | Clear local state safely; no replay into the new context |
| Tap times out or becomes disabled | Stop geometry and invalidate pending work | Cleanup first, then bounded recovery if still eligible |

Escape restoration is best effort using the same public AX methods, current constraints, and timeouts. It may fail if the target closed, access changed, or the original size is no longer accepted. Do not loop or modify another window. Restoring moving uses position only; restoring resizing may restore size and position. Log a restoration failure without showing a blocking alert during the drag.

Once a physical down has been consumed, never replay it as an ordinary click after manipulation has begun. No synthetic mouse-up is needed by the target for a down it never received. Track actual button state after exceptional tap recovery; if it is still held, continue draining before admitting another gesture. No state may consume future unrelated clicks indefinitely.

On normal suspension/disable, leave the tap alive only long enough to drain the owned sequence. On explicit quit, allow at most 500 ms of drain, then tear down and terminate; do not keep the process alive awaiting a user who continues holding a button. At forced tap loss/process termination, balanced delivery cannot be guaranteed because interception itself is unavailable. Clear application state, never synthesize a replacement click, and require a fresh physical down for the next operation.

## 10. Window Resizer settings and feedback

### 10.1 Required controls and defaults

| Setting | Default | Allowed values / dependency |
| --- | --- | --- |
| Enable Window Resizer | On | Utility-level switch |
| Resize Windows | On | Independent gesture switch |
| Resize Activation | Immediate | Immediate; After Small Drag |
| Resize Drag Threshold | 5 points | Integer 1–30; editor available only in After Small Drag |
| Resize Corner Size | 200 points | Integer 8–400 |
| Move Windows | On | Independent gesture switch |
| Move Drag Threshold | 5 points | Integer 1–30; threshold activation always used |
| Change Cursor During Gestures | On | Boolean; includes eligible Command hover and active gesture |
| Show Corner Hints | On | Boolean; eligible corner while Command is held |
| Show Window Outline | Off | Boolean; actual accepted frame during active resize or move |
| Reset Window Resizer | Action | Confirm, then restore this utility's defaults |

Help text MUST state fixed Command/right-button and Command/left-button shortcuts, the distinction between corner and interior regions, threshold click-delay limitations, finish on Command/button release, Escape restoration, inactive-window behavior, and off-screen allowance.

The 5-point movement threshold is not linked to resize activation or its threshold. A change to resize Immediate MUST NOT change moving behavior. Settings changes are persisted immediately; visual feedback preferences may update during an active gesture, but geometry/activation parameters remain the gesture's initial snapshot. Disable and suspension always terminate immediately as defined above.

### 10.2 Cursor and overlays

When enabled and Command is held over an eligible resize corner, show the appropriate diagonal resize cursor; over an eligible moving interior, show an open-hand cursor, changing to closed hand during active moving. Use public `NSCursor` capabilities; create a static custom diagonal cursor asset if the SDK lacks a suitable public cursor. Do not use private cursor selectors, hide the pointer, or warp it.

Cursor changes outside the app are best effort: another app may replace the cursor. Do not enter a high-frequency race with it. Restore cursor ownership on every exit path, including modifier release, hover exit, permission loss, suspension, errors, sleep, and quit. If cursor feedback cannot be reliable on a supported configuration, retain gesture function and document the visual limitation.

Corner hints are small translucent marks at the eligible corner of the current hover target, shown only with Command held, resizing enabled, and engine ready. Do not outline every window or show hints for unsupported targets. The optional active outline follows the actual accepted AX frame and supports both resizing and moving. No screen images or window content are captured.

Use borderless, transparent, nonactivating AppKit panels/windows with `ignoresMouseEvents = true`. They must never become key/main, steal focus, enter target hit testing, or intercept input. Use a public window level that keeps hints visible above the target without covering security prompts or unrelated system UI. Split/clamp drawing per display as necessary; do not visually connect across gaps between displays.

Use semantic accent color, an approximately 2-point outline, and accessible contrast. Respect Reduce Motion with no pulsation or animated resizing of hints. Hide all feedback if the session is inactive, the feature is unavailable, or Command is not held; the active outline may remain only until the gesture ends. Do not add sounds or global notifications.

## 11. Preferences, migrations, and resets

### 11.1 Storage

Persist application preferences in the application's standard UserDefaults domain, keyed by a stable bundle identifier. Use typed accessors and register defaults once before runtime reconciliation. No database or document package is needed. The release owner must choose the organization's actual reverse-DNS bundle identifier before signing and keep it stable; this specification does not invent organizational identity.

| Key | Type | Default |
| --- | --- | --- |
| `preferences.schemaVersion` | Integer | 1 |
| `global.suspendAll` | Boolean | false |
| `windowResizer.enabled` | Boolean | true |
| `windowResizer.resizeEnabled` | Boolean | true |
| `windowResizer.resizeActivation` | String enum | `immediate` |
| `windowResizer.resizeThresholdPoints` | Integer | 5 |
| `windowResizer.cornerSizePoints` | Integer | 200 |
| `windowResizer.moveEnabled` | Boolean | true |
| `windowResizer.moveThresholdPoints` | Integer | 5 |
| `windowResizer.changeCursor` | Boolean | true |
| `windowResizer.showCornerHints` | Boolean | true |
| `windowResizer.showWindowOutline` | Boolean | false |
| `general.launchAtLoginRequested` | Boolean | false; Release login intent only |
| `onboarding.assistantVersion` | Integer | 0 until first deliberate presentation |
| `onboarding.assistantDisposition` | String enum | `notStarted`, then `skipped` or `completed` |
| Standard AppKit frame-autosave data | AppKit-managed | No initial saved frame |

UI selection, search text/results, current gesture, runtime failure counters, permission grants, sample edits, and sample history are not saved as functional preferences. Keep scripts preview data in memory; reseed on application process launch or Reset Scripts Preview. Closing/reopening Settings within the same process retains preview edits.

Reject wrong types, unknown enum cases, and nonfinite numeric input. Clamp numeric values loaded from preferences to documented limits; show a one-time nonblocking diagnostic if repair was needed and log the repair. User-entered out-of-range numbers are rejected inline rather than silently clamped. A malformed key must not crash startup or reset unrelated preferences.

Schema migrations are small, ordered transformations in the preference store. Preserve unknown future keys; never delete the entire defaults domain as a migration shortcut. Persist migrated schema version only after the corresponding transformation succeeds. If the stored schema is newer than supported, preserve it and avoid destructive migration; use safe known values and show an unsupported-preferences warning.

### 11.2 Reset behavior

All resets use a native confirmation sheet identifying the exact scope, with Reset and Cancel. Navigation to a reset result never confirms it.

- **Reset Window Resizer:** end an active gesture at its accepted frame, restore only `windowResizer.*`, and reconcile eligibility. Preserve master suspension, login intent, assistant state, and logs.
- **Reset Scripts Preview:** recreate the fixed sample rows/history and preview controls in memory; this has no functional runtime effect.
- **Reset All Preferences:** end active gestures, restore known preference defaults including Suspend All = off and utility switches = on, clear saved window layout, and reset scripts preview. Explicitly warn that this can resume enabled features if permissions are already granted. Preserve OS permission grants, assistant disposition, and existing log files. Use the separate assistant relaunch action to repeat guidance.

Reset All also requests login unregistration in the eligible Release app. If unregistration fails, reflect the actual OS registration state and show the error rather than falsely reporting that startup was disabled. Cancel performs no mutation. Apply a reset as one coordinated state change to avoid briefly starting features between individual key changes.

## 12. Launch at login and distribution

### 12.1 Release-only preference

Provide **Launch Jimmy Tweaks at Login**, off by default, only in Release builds eligible for distribution. Compile out both its control and registration-changing code from other builds. Do not expose a build/environment selector or runtime management page.

Use `SMAppService.mainApp` to register/unregister the existing main app; do not create a separate login executable. The OS is the authority for actual registration state. Show enabled, disabled, requires approval, not found, and failure states distinctly, with an Open Login Items Settings action if approval is needed. Preserve requested intent separately from actual state. See [SMAppService mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) and [service registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).

Register only after an explicit toggle action in an installed, correctly signed Release app in a supported Applications location. If the app is running from a read-only image, a temporary/translocated location, or another unsuitable location, disable the preference with instructions to move it to Applications. Do not silently copy or relaunch it elsewhere. Ordinary startup must not repeatedly re-register or override a change the user made in System Settings.

Turning the preference off unregisters it; it does not quit the current process. Quitting leaves the preference as configured for the next login. Saved Suspend All always wins on login startup. Login launch performs no automatic permission prompts and opens no Settings window.

### 12.2 Direct delivery

Distribute a signed `.app` in a downloadable disk image, with clear drag-to-Applications instructions. The distribution owner supplies the real Team ID, bundle ID, version, and build number before shipping. Keep these identities consistent so saved preferences, login registration, and system permission association remain stable.

Sign with Developer ID Application, enable Hardened Runtime, include secure timestamps, notarize through the current supported Apple workflow, staple the applicable notarization tickets, and validate the exported app and final disk image. Do not ship development-only signing entitlements. Use only entitlements actually needed by the chosen public APIs. See [Apple’s notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

Test a quarantined download on a clean user account or Mac, including first launch, installation in Applications, permission grant, silent login launch, reopen, and explicit quit. Test offline opening of the stapled distribution. Manual installation of a newly distributed application version is sufficient for this product scope.

## 13. Reoccurring Scripts — NONFUNCTIONAL UI STUB

### 13.1 Hard boundary

This page demonstrates a possible future interface only. It MUST NOT schedule or execute anything. Do not add a timer that represents a schedule, background task registration, shell/interpreter calls, subprocess creation, AppleScript evaluation, URL retrieval, script download, notification, or real success/failure result. Do not create a scheduler or execution service with empty implementations “for later.” There is no functional scripts subsystem in this version.

Maintain this permanent page banner: **“NONFUNCTIONAL UI STUB. These are sample scripts and sample results. Nothing is downloaded, scheduled, or executed.”** Status, search results, and all action feedback must retain this distinction. The global Suspend All preference does not prevent preview editing because editing has no background behavior.

### 13.2 Compact sample list and detail

Use a compact native table with approximately 32-point rows, single-line name, abbreviated URL, and a short **Sample** badge. Keep full URLs in the detail field/help rather than creating oversized cards. Include these fixed seed examples using reserved documentation domains:

| Stable sample ID | Name | Sample script URL | Interval label |
| --- | --- | --- | --- |
| `sample.cleanup` | Temporary File Cleanup | `https://example.com/scripts/cleanup.sh` | Every 1 hour |
| `sample.backup` | Notes Backup | `https://example.org/scripts/backup.sh` | Every 6 hours |
| `sample.health` | System Health Check | `https://example.net/scripts/health-check.sh` | Every 30 minutes |

These are illustrative URL strings, not working endpoints. Never resolve, fetch, preview, or open them in a browser. Do not create clickable links that imply executable sample content exists.

The selected-row detail contains Name, Script URL, Interval, and an Enabled toggle labeled **Enabled in Preview**. The page-level toggle is **Enable Scripts Preview**, default off. Neither toggle changes runtime health, permissions, login behavior, or creates work. Preserve the selected sample's values while the page-level toggle is off and explain the preview dependency.

### 13.3 UI-only controls

| Control | Allowed behavior |
| --- | --- |
| Enable Scripts Preview | Enables/disables demonstration editing; no functional activation |
| Enabled in Preview | Changes a row's in-memory check state only |
| Add Sample | Adds an in-memory sample row with a unique preview ID; no file/URL access |
| Duplicate | Duplicates the selected preview row in memory |
| Remove | Removes the selected row from the preview; no file deletion |
| Name | Editable plain text, 1–80 characters after trimming |
| Script URL | Editable HTTPS URL string with a host, max 2,048 characters; syntax validation only |
| Interval | Popup: Every 5 minutes, Every 30 minutes, Every 1 hour, Every 6 hours, Every day; informational only |
| Run Now (Preview Only) | Shows “Preview only — nothing was executed.” No run record is appended |
| Clear Sample History | Clears only in-memory fictional history; does not clear the application log |
| Reset Scripts Preview | Restores seed data and sample history after confirmation |

Disable selected-row controls when no row is selected; announce the reason. A malformed URL gets an inline validation message but is never tested over the network. Add, duplicate, remove, and field edits take effect immediately in the preview. Removing the last row shows **“No sample scripts. Add a sample to explore the preview.”** with Add Sample; it must not imply scripts are waiting to be scheduled.

### 13.4 Sample Run History

Heading: **Sample Run History**. Explanation: **“Fictional examples shown for layout only. No scripts have run.”** Use a native table with Example Time, Script, Sample Result, and Sample Duration.

Seed three static rows:

| Example Time | Script | Sample Result | Sample Duration |
| --- | --- | --- | --- |
| Example day · 09:00 | Temporary File Cleanup | Sample success | 0.4 seconds |
| Example day · 08:30 | System Health Check | Sample failure | 1.2 seconds |
| Example day · 06:00 | Notes Backup | Sample skipped | — |

Use static example times, not the current date or a live countdown. No Next Run, actual execution timestamp, actual output, or live progress indicator is permitted. Historical sample rows retain their sample names if a preview script is renamed or removed. Empty history reads **“No sample history. Nothing has been executed.”** with Reset Scripts Preview as the repopulation action. All changes disappear on process restart.

## 14. Logging and local data

### 14.1 Normal logging

Logging is always **Normal**, with no verbosity selector in this release. Write UTF-8 plain-text files under `~/Library/Logs/Jimmy Tweaks/`. Use one serialized writer and daily UTC file names such as `Jimmy-Tweaks-2026-10-29.log`. Rotate at UTC midnight; if a file reaches 5 MiB, start a numbered segment for that date. Use owner-only directory/file permissions where supported.

Each line includes an ISO 8601 UTC timestamp, severity, component, stable event name, and concise human-readable message. Include app version/build and a process-session identifier at startup. Log:

- Launch reason, shutdown, and preference schema migration/repair.
- Suspension, relevant preference changes, permission transitions, engine state transitions, and retry outcomes.
- Gesture start/end/cancel, operation kind, selected corner, duration, and coarse failure category.
- AX errors, unsupported-target summaries, event-tap disablement, restoration failure, and log I/O errors.

Do not log every pointer sample or geometry write. Rate-limit repeated target errors to one detailed entry per target/error category per 60 seconds, with a count summary. Avoid retaining window references just for logging. Sample UI interactions may log an explicit `preview` action if useful, but never record them as script runs.

Do not log typed keys, window titles, document names, window contents, full pointer traces, user-entered script URLs/content, credentials, or personal file paths. A target bundle identifier and AX error code are sufficient for routine compatibility diagnostics. Logs stay local and are never uploaded automatically.

### 14.2 Seven-day retention and opening logs

Retention is a rolling **168 hours**. On startup, rotation, and once per hour while the agent is running, delete only app-owned closed log segments whose newest recorded event is older than the cutoff. For a closed segment straddling the cutoff, atomically rewrite it with only records at or after the cutoff, preserving its plain-text format. Use recorded UTC timestamps, with file modification time as a fallback for a damaged/empty segment. After a successful cleanup, no retained parseable record is older than seven days; hourly cleanup may leave expired records for up to one hour while running. Files are cleaned on the next launch when the app was not running.

Do not delete arbitrary files in the directory or rewrite an active file. Rotate first if an inactive-over-seven-days file is reopened, then clean it. Handle clock jumps conservatively: close/rotate an active segment if the new cutoff would expire its contents, preserve future-dated records until their timestamps become eligible, and do not loop on deletion failure. Write/prune failures remain visible as Logging errors and must never delete the only valid copy of a retained segment. Retention and rotation are log maintenance only.

**Open Log File** MUST flush the current writer and open the current plain-text file through `NSWorkspace` using the user's default text application. It MUST NOT invoke a shell or redirect the user to a system log viewer. Create today's file with a startup/header entry if necessary. **Reveal Logs Folder** reveals the directory in Finder. These actions are available from Status and Logging even when window features are suspended or unavailable.

Logging failure MUST NOT stop window manipulation. Keep a bounded in-memory diagnostic buffer of at most 200 records, expose a nonblocking Logging error with Retry/Open Folder where meaningful, and rate-limit attempts to re-open the writer. Do not recursively log logger failures. Open Log File reports a readable error if no accessible current file can be created/opened.

### 14.3 Data inventory

Persistent local data comprises UserDefaults, Settings frame-autosave data, and retained log files only. Runtime caches contain transient AX references and geometry; clear them on relevant process/session changes. Scripts examples and edits are in-memory only. No screen capture, script payload storage, external synchronization, or remotely stored settings are needed.

## 15. Focused verification and acceptance criteria

### 15.1 Test strategy

Use deterministic tests for geometry, gesture state/event ordering, preference validation, search matching/navigation metadata, retry budgets, and log retention. Use a small native test window fixture capable of accepting, clamping, rejecting, delaying, and invalidating AX attributes. The fixture is test tooling, not a shipped helper. Test real application compatibility manually on supported macOS 27 hardware; do not substitute synthetic tests for permission, cursor, or target-app behavior.

Avoid broad UI snapshot suites. A compact smoke test for Settings navigation, search empty state, persistent suspension, and scripts stub boundaries is sufficient, supplemented by the targeted matrix below. Tests must exercise outcomes and event invariants rather than mirror internal class structure.

### 15.2 Required acceptance matrix

| ID | Scenario | Pass condition |
| --- | --- | --- |
| A01 | First deliberate launch with no grant | One Settings window and skippable assistant; no working-utility claim before access |
| A02 | Skip, close, reopen assistant | Settings usable; skip persists; relaunch guidance available without repeated prompts |
| A03 | Grant/revoke access while running | Enable eligible features automatically on grant; stop safely on revocation; suspension remains authoritative |
| A04 | Background/reopen/quit | Settings close leaves process running; deliberate reopen returns one window; explicit quit terminates |
| A05 | Suspend during pending/active gesture; relaunch | No new writes after in-flight request; safe event cleanup; saved suspension remains on |
| A06 | Per-utility and gesture switches | Resize/move operate independently; saved intent survives missing permissions and suspension |
| A07 | All four resize corners | Correct signs and origin formulas; opposite anchor steady within 1 point on cooperative targets |
| A08 | Immediate resize click/drag | Eligible click consumed; no context menu; motion starts without a drag threshold |
| A09 | Threshold boundary | 4.99 points stays pending at threshold 5; 5.00 activates; diagonal Euclidean displacement and independent settings correct |
| A10 | Moving | Interior Command + left-drag keeps initial cursor offset and size; default 5-point threshold, configurable independently |
| A11 | Normal input preservation | Plain clicks/drags, nonqualifying modifiers, wrong buttons, edge/title-bar left drags, Finder Command-selection, browser Command-clicks work; no duplicate down/up |
| A12 | Finish/cancel | Mouse-up and Command release keep frame; Escape attempts restoration; re-pressing Command during drain does not restart |
| A13 | Unsupported windows | Nonresizable/movable-only, dialogs, floating panels, sheets, minimized/full-screen/system/own-app windows handled according to capabilities |
| A14 | App-imposed constraints | Minimum/maximum, aspect ratio, incremental sizing, and rejected position respected; no negative dimensions or correction loop |
| A15 | Focus | Resizing/moving an inactive cooperative window leaves its app inactive and stacking unchanged |
| A16 | Multiple displays | Fractional/negative coordinates, different scales, stacked layouts, cross-display drag, partial off-screen frames; no coordinate jump |
| A17 | Environmental transitions | Space change, display removal, sleep/wake, lock, fast user switch safely end gesture and revalidate |
| A18 | Target stalls/dies | AX timeouts cannot block input/Settings; no stale work hits another target; ordinary next click works |
| A19 | Tap failure | Bounded 1/2/4-second recovery and rolling cap; exhaustion shows Failed; Retry works; no infinite restart |
| A20 | Feedback | Correct corner/hand cursor; optional hints/actual-frame outline; no focus/input capture; clean teardown on every exit path |
| A21 | Search | Labels/descriptions/keywords/diacritics/token ranking; per-control navigation/highlight; disabled controls; empty state; Escape; no action accidentally executed |
| A22 | Native UI accessibility | Keyboard-only navigation, VoiceOver labels/values/reasons, light/dark, increased contrast, Reduce Motion; all content reachable at minimum window size |
| A23 | Preferences/reset | Immediate application; range/type repair; unknown enums; scope-correct resets; Cancel no-op; reset does not erase permission grants/logs |
| A24 | Login preference | Exists only in eligible Release app; actual OS registration reflected; silent startup honors suspension; user OS changes not overridden |
| A25 | Scripts boundary | Every control changes only preview state or explicit preview feedback; URLs never fetched/opened; no schedule, execution, real history, or background work after leaving page |
| A26 | Scripts presentation | Compact sample URLs, permanent stub labels, fictional static history, row/history empty states, seed reset and process restart behavior |
| A27 | Logging | Plain-text file opens; retention/segments/cutoff verified with a controlled clock; no pointer/key/content leakage; I/O failure nonfatal |
| A28 | Distribution | Correct signature, Hardened Runtime, notarization and stapling; clean-account quarantined and offline launch; installed reopen/login behavior |

### 15.3 Representative manual compatibility set

Exercise at least Finder, Safari or another native browser, TextEdit, Terminal, System Settings, one application using a non-AppKit UI framework, and native fixture dialogs/panels. Include active and inactive windows, overlapping windows, a constrained-size window, and a target that changes its own frame during a gesture. Publish supported behavior and known incompatibilities from observed results; do not advertise universal compatibility.

Test ordinary Command-click and rapid double-click sequences with a mouse and a trackpad. Include Command released before button-up, Escape followed by continued physical hold, a second mouse button during drag, tap loss during hold, and replay markers passing through other event taps. Verify that no post-cancellation geometry sample runs late.

### 15.4 Performance and reliability targets

- On a declared Apple silicon reference machine, background idle CPU should average below 0.5% of one core over five minutes, excluding deliberate interaction and OS activity.
- No continuous window enumeration or pointer-rate AX queries when Command is not held and no gesture is active. Hover checks while Command is held are coalesced to at most 20 Hz.
- On the cooperative fixture, target pointer-to-accepted-frame latency is ≤50 ms p95 during ordinary dragging. Treat the 75 ms admission deadline separately. Report real-app latency rather than claiming the same guarantee for unresponsive targets.
- No unbounded event buffers, retry loops, retained AX objects, or growth in overlay windows across 500 consecutive gestures.
- Settings remains responsive during target AX stalls, log failures, and retries. Suspension and Escape must enqueue termination without waiting on AX.
- The scripts page creates no repeating work or network traffic before, during, or after preview interactions.

## 16. Resolved edge decisions and platform constraints

The following choices make unspecified behavior concrete and are normative for this version:

| Topic | Resolution |
| --- | --- |
| Window coverage | All capability-eligible windows, including independent dialogs/panels/sheets; protected or unsupported elements pass through |
| Off-screen geometry | Allowed; no application-imposed screen clamp |
| Settings count and edits | One window; immediate valid edits; per-utility and application preference resets |
| Resize corner selection | Inward 200-point squares, adjustable 8–400; nearest-corner tie rule |
| Moving region | 12-point interior inset plus title-bar/content exclusion, fallback 32-point top exclusion |
| Resize activation | Immediate default; optional threshold mode with independent default 5, range 1–30 |
| Moving activation | Always threshold-based, independent default 5, range 1–30; no Immediate moving selector |
| Threshold reference | Euclidean displacement from original down; initial frame/pointer retained on activation |
| Additional modifiers | Initial Shift/Option/Control disqualify; adding one ends active manipulation |
| Ordinary release | Keep accepted geometry; Command release drains remaining owned button sequence |
| Escape | Best-effort original-frame restoration after activation; discard unclaimed candidate before activation |
| Suspend/disable/environment change | Keep last accepted geometry; no automatic rollback |
| Mid-gesture preference changes | Geometry settings apply next gesture; disable/suspend act immediately; visual switches may update live |
| Feedback defaults | Cursor and corner hints on; active window outline off |
| Permission recovery | Automatic when enabled/eligible; no forced restart by design; no repeated automatic prompting |
| Engine failure | Three bounded retries, then visible Failed; target-specific unsupported behavior is not a global engine fault |
| Preview persistence | In-memory for the current process only; no background scripts behavior |
| Log retention | Rolling seven-day cutoff; delete expired closed segments, prune the boundary segment, run cleanup hourly and at startup |
| First-run guidance | First deliberate open only; skipped/completed state saved; relaunchable at any time |

Public AX APIs cannot atomically change size and position, force another app to accept arbitrary frames, or reliably expose every app's min/max size. Public input interception cannot guarantee perfect replay through every third-party input tool, secure input context, or forced permission/tap shutdown. Global cursor ownership can also be contested by the target app. The implementation MUST handle these limits with bounded work and truthful status/help rather than private APIs or unsupported guarantees.

The deployment target is a product requirement. Validate actual behavior and permission labels against the shipping macOS 27 SDK and tested OS versions. Earlier Apple documentation establishes the public API contracts cited here; it does not prove version-specific behavior on every future point release.

## 17. Implementation completion checklist

The application is ready for delivery only when:

1. Lifecycle, one-window native Settings, persistent suspension, and truthful effective state are implemented.
2. Every Settings/action control is represented in the local metadata catalog and result navigation works without executing actions.
3. The skippable, relaunchable permission assistant and live capability reconciliation work on a clean account.
4. All four anchored resize corners, independent moving, event ownership, replay, termination, and failure paths satisfy the focused tests.
5. Optional cursors/overlays never intercept input or activate the target.
6. Defaults, resets, normal logging, logfile opening, retention, and Release-only login preference meet this specification.
7. The scripts page is visibly a stub and inspection confirms there is no scheduler or execution path.
8. The signed and notarized distribution passes installation, clean launch, reopen, login, and offline validation.
9. Observed target-app compatibility limits and the tested OS/toolchain/reference hardware are recorded with the delivered build.

No application code is included in this specification deliverable.
