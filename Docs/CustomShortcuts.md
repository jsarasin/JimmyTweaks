# Custom Shortcuts

Custom Shortcuts is a native AppKit module in the existing Jimmy Tweaks agent. It is off by default. Definitions, independent enabled switches, trigger modes, hardware input identities, and ordered action instances persist in the application's existing UserDefaults domain.

## Use

1. Open **Custom Shortcuts**, enable it, and add a shortcut with **+**.
2. Choose Transparent or Absorbing, then use **Record Shortcut**. Press a keyboard combination or a mouse button, and confirm with **Use Shortcut**. Ordinary typing needs a modifier. Escape is reserved; hold it for two seconds to cancel recording. Click **Record Again** to replace a candidate.
3. Unmodified left/right clicks require Transparent. To change an existing Absorbing shortcut to one of these combinations, choose Transparent first. Duplicate combinations and enabled Window Move & Resize Command+left/right gestures are rejected regardless of shortcut mode or activation phase. If Window Move & Resize is subsequently enabled with a conflicting gesture, that gesture takes precedence and the affected custom shortcut is inactive with an explanation.
4. Add actions from the searchable, categorized picker. Drag rows, or select one and use Up/Down. Select a Delay to edit its decimal seconds or logarithmic slider (0.001–60 seconds).
5. **Test Shortcut** observes the selected enabled shortcut for ten seconds without running its actions. Switch to another application to test keyboard input. A timeout reports that no input was received; success establishes receipt, not priority over other applications.

Empty definitions are allowed and stay inactive. Settings can be closed while shortcuts operate. Keyboard shortcuts ignore Jimmy Tweaks when it is active. Mouse shortcuts use the frontmost hit window's number to identify Jimmy Tweaks windows, and release activation retains the original press identity.

## Input and permissions

Transparent definitions use a Core Graphics `listenOnly` session tap whose callback always returns the original event. Absorbing definitions share Window Move & Resize's active session tap. Matching active downs, repeats, corresponding ups, and mouse drags are consumed; unrelated events pass through. The press's modifiers determine release activation. Absorption ownership drains through release even after a definition is disabled.

The shared active tap runs on the main run loop so AppKit ownership checks stay on main. Window Move & Resize's existing asynchronous Accessibility traversal/writes and generation guards remain intact. No action executes inside an input callback. No ordinary typed characters are retained by the router: character translation is confined to the recorder, and matching uses hardware codes and normalized modifiers. Caps Lock state is ignored.

Accessibility/input-control readiness uses the existing permission coordinator. Passive observation is installed only for Transparent shortcuts or an open recorder. The module’s permission hyperlinks navigate to matching entries in **Permissions**. Missing Input Monitoring access is requested automatically once per launch; each entry provides its own System Settings button and live status. The visible Permissions page polls every two seconds while any access is missing, without repeating requests. Already-granted Accessibility can also permit listening, but tap creation must actually succeed. Missing grants and interruptions have visible statuses and no fallback from Absorbing to Transparent. Active recovery uses the existing bounded retry budget. Passive interruption recovery is limited to three creations per enable/permission change or explicit Retry.

macOS can withhold input through Secure Keyboard Entry, protected shortcuts, or earlier interceptors. No application can promise global interception priority or balance events which macOS delivers during a tap outage. Ownership is reconciled against physical state on recovery. No system or third-party shortcut preferences are read or modified.

Apple documents the distinction between a [passive listener](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/listenonly) and an [active filter](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/defaulttap).

## Execution and cancellation

Each shortcut has one independent cancellable task. Different shortcuts can overlap; a second invocation of a running shortcut is rejected. Actions within a task always complete sequentially, and failure or cancellation prevents subsequent actions. Removing or disabling a shortcut cancels its task. Master Suspend, module disable, session loss, or complete loss of input permission cancels all tasks.

Escape cancels every running task and pending dispatch, including while Jimmy Tweaks is active or recording. It is passed through by the shortcut router. One nonactivating floating message reads **Scripts canceled due to Escape key**, then disappears. Suspend/disable cancellation does not display this message.

Delay uses cancellable `Task.sleep`. Screen selection invokes only `/usr/sbin/screencapture -i -s -c`; it creates no output file or custom overlay. It waits for the initiating mouse button's physical release, awaits process completion, and verifies a new image on the clipboard. Cancellation or utility failure stops the sequence. Native selections are serialized when concurrent sequences reach screenshot actions; the sequences otherwise remain independent. New shortcut and Window Move & Resize gesture admission is paused during screenshot selection to avoid recursion. Cancellation terminates only the owned utility process, with bounded escalation if termination fails. Operating-system operations may take time to acknowledge termination.

Quitting waits up to three seconds for action cancellation after input cleanup, including the owned process's one-second forced-termination fallback. A cancellation timeout is logged; a pending permission reset is skipped if cancellation did not finish.

## Extending actions and future scripts

`ShortcutActionDefinition` supplies a stable ID, name/category/description, default parameters, summary, validation, optional AppKit editor, and asynchronous execution closure. The editor and picker contain no switch over built-in action types. Register or remove definitions through `ShortcutActionRegistry`; the picker and configured action names refresh dynamically. Unavailable definitions remain stored and are marked explicitly, and their shortcuts stay inactive.

A future Scripts module can register `script:<stable definition ID>` actions with its current user-facing names and execution-service closures. The closure should resolve the script by ID and propagate task cancellation to its own runner and owned children. Shortcut parameters need not contain a copy of script configuration. The existing sample Scripts page remains inert; its sample URLs are not runnable actions. The dynamic Scripts category is present even before an execution service exists. No script engine is included here.

## Verification

`Scripts/test.sh` covers pure input matching, duplicate/gesture conflicts, press/release and repeat handling, own-window exclusion decisions, balanced absorption after disable, recorder hardware capture and Escape timing, preference persistence, sequential and concurrent execution, failure propagation, cancellable delays, owned child-process termination, and global Escape/Suspend/disable routing. The native smoke harness visits all eight pages and exercises populated shortcut editing, Up/Down ordering with persistent instance IDs, Delay decimal editing, picker search, and module-to-permission navigation with scrolling and highlighting. It uses isolated preferences and does not grant permissions or invoke screen capture.

The remaining interactive acceptance checks require a permitted installation: physical keyboard/mouse recording and drag/drop, Transparent delivery to a foreground app, absorbing down/up/drag behavior, exact hit ownership across overlapping application windows, real tap interruptions and grant/revocation, native screenshot crosshairs and clipboard content, Escape popup focus behavior, and Window Move & Resize coexistence across Spaces and sleep/wake. These are not claimed as automated passes.
