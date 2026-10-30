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
