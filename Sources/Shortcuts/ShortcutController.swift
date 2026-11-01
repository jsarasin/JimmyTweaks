import AppKit
import ApplicationServices
import Carbon

extension Notification.Name { static let shortcutsChanged = Notification.Name("JimmyTweaks.shortcutsChanged") }

private func shortcutPassiveCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo = userInfo {
        Unmanaged<ShortcutController>.fromOpaque(userInfo).takeUnretainedValue().observe(type: type, event: event)
    }
    // This callback ALWAYS returns the original event. The tap itself is also listen-only.
    return Unmanaged.passUnretained(event)
}

/// Main-run-loop router shared with Window Resizer's active tap. Only passive observation
/// installs another tap; no shortcut action executes inside either event callback.
final class ShortcutController {
    let registry = ShortcutActionRegistry()
    let runner: ShortcutActionRunner
    private let preferences: PreferenceStore
    private let permissions: PermissionCoordinator
    private let logger: FileLogger
    private var passiveTap: CFMachPort?
    private var passiveSource: CFRunLoopSource?
    private var passiveMatcher = ShortcutMatcher()
    private var activeMatcher = ShortcutMatcher()
    private var eligible: [ShortcutDefinition] = []
    private var available = false
    private var activeReady = false
    private var passiveAttempts = 0
    private var passiveRetry: DispatchWorkItem?
    private var lastPermission = false
    private var interactive = false
    private var wantsPassive: Bool { recorder != nil || available && eligible.contains { $0.mode == .transparent } }
    private var recorder: ShortcutRecorderController?
    private var testID: UUID?
    private var testReportID: UUID?
    private var testGeneration = UUID()
    private var testResult = ""
    private var testReceived = false
    private var executionErrors: [UUID: (definition: ShortcutDefinition, message: String)] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var status = "Custom Shortcuts is switched off."
    private var toast: NSPanel?
    private var toastDismiss: DispatchWorkItem?
    private var pendingDispatch = Set<UUID>()
    private var generation: UInt64 = 0
    var onRetry: (() -> Void)?
    var onNeedsReconcile: (() -> Void)?
    var needsObservationPermission: Bool { wantsPassive && passiveTap == nil }
    var needsInterceptionPermission: Bool { available && eligible.contains { $0.mode == .absorbing } && !activeReady }
    var blocksGestures: Bool { recorder != nil || interactive }
    var hasAbsorbedPress: Bool { activeMatcher.hasAbsorbedPress }
    var needsActiveTap: Bool { available && eligible.contains { $0.mode == .absorbing } || activeMatcher.hasAbsorbedPress }

    init(preferences: PreferenceStore, permissions: PermissionCoordinator, logger: FileLogger) {
        self.preferences = preferences; self.permissions = permissions; self.logger = logger
        runner = ShortcutActionRunner(registry: registry, logger: logger)
        runner.onEscape = { [weak self] in self?.showCancellation() }
        runner.onFailure = { [weak self] id, message in
            guard let self = self, let row = self.preferences.shortcuts.first(where: { $0.id == id }) else { return }
            self.executionErrors[id] = (row, message); self.errors[id] = message; self.changed()
        }
        runner.onInteractiveChanged = { [weak self] active in self?.interactive = active }
        registry.onChange = { [weak self] in self?.onNeedsReconcile?(); self?.changed() }
    }
    func reconcile(sessionActive: Bool) {
        let wasAvailable = available
        available = preferences.bool(.shortcutsEnabled) && !preferences.bool(.suspended) && sessionActive
        let rows = preferences.shortcuts
        executionErrors = executionErrors.filter { rows.contains($0.value.definition) }
        errors = executionErrors.mapValues(\.message)
        eligible = rows.filter { shortcut in
            if let error = ShortcutConflictChecker.error(for: shortcut, among: rows, gestures: preferences.gesture) { errors[shortcut.id] = error; return false }
            if let error = registry.unavailableReason(shortcut.actions) { errors[shortcut.id] = error; return false }
            return shortcut.enabled && shortcut.combination != nil && (shortcut.configured || testID == shortcut.id)
        }
        if !available {
            generation &+= 1; pendingDispatch.removeAll(); runner.cancelAll()
            passiveMatcher.cancelActivations(); activeMatcher.cancelActivations()
        } else {
            let ids = Set(eligible.map(\.id))
            runner.retainOnly(ids)
        }
        if !permissions.accessibility && !permissions.inputMonitoring { runner.cancelAll() }
        let listenGranted = permissions.inputMonitoring
        if listenGranted != lastPermission || !wasAvailable && available { passiveAttempts = 0; lastPermission = listenGranted }
        if wantsPassive && (listenGranted || permissions.accessibility) { startPassive() }
        else { stopPassive() }
        if !available { status = preferences.bool(.suspended) ? "Custom Shortcuts is suspended." : "Custom Shortcuts is switched off or the session is inactive." }
        else if wantsPassive && passiveTap == nil {
            status = listenGranted ? "Input observation could not start. Use Retry; macOS may require restarting Jimmy Tweaks after a permission change." : "Input observation is unavailable. Review Permissions → Input Monitoring, then retry."
        }
        else if eligible.contains(where: { $0.mode == .absorbing }) && !activeReady { status = "Absorbing shortcuts need an available Accessibility input tap. Transparent shortcuts can still operate." }
        else { status = "Ready. Global shortcuts ignore Jimmy Tweaks’ own windows." }
        changed()
    }
    func retry() { passiveAttempts = 0; permissions.refresh(); onRetry?() }
    func activeTapReady(_ ready: Bool) {
        activeReady = ready
        if ready { discardReleasedOwnership() }
        if !ready && available && eligible.contains(where: { $0.mode == .absorbing }) {
            status = "Absorbing input was interrupted. Waiting for recovery; use Retry if it remains unavailable."
        }
        if ready && available { status = wantsPassive && passiveTap == nil ? "Active input is ready. Input Monitoring is needed for Transparent shortcuts." : "Ready. Global shortcuts ignore Jimmy Tweaks’ own windows." }
        changed()
    }
    func discardReleasedOwnership() {
        activeMatcher.discardReleased { input, code in
            if input == .key { return CGEventSource.keyState(.hidSystemState, key: code) }
            guard let button = CGMouseButton(rawValue: UInt32(code)) else { return false }
            return CGEventSource.buttonState(.hidSystemState, button: button)
        }
    }
    func shutdown() {
        available = false; generation &+= 1; runner.cancelAll(); recorder?.cancel(); recorder = nil
        passiveRetry?.cancel(); stopPassive(); toast?.orderOut(nil)
    }
    private func changed() { NotificationCenter.default.post(name: .shortcutsChanged, object: self) }
    private func startPassive() {
        guard passiveTap == nil, passiveRetry == nil, passiveAttempts < 3 else { return }
        passiveAttempts += 1
        let types: [CGEventType] = [.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: shortcutPassiveCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            logger.log("shortcuts", "listen.unavailable", "The passive input tap could not be created.", severity: "WARN"); return
        }
        passiveTap = tap; passiveSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), passiveSource, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func stopPassive() {
        if let source = passiveSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = passiveTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        passiveTap = nil; passiveSource = nil; passiveMatcher.reset()
    }
    fileprivate func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stopPassive(); status = "Input observation was interrupted. Retrying within the recovery limit."
            logger.log("shortcuts", "listen.interrupted", "Passive input tap interrupted.", severity: "WARN")
            let work = DispatchWorkItem { [weak self] in self?.passiveRetry = nil; self?.onNeedsReconcile?() }
            passiveRetry = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            DispatchQueue.main.async { [weak self] in self?.changed() }; return
        }
        guard !Self.synthetic(event) else { return }
        escape(type: type, event: event)
        if let recorder = recorder { recorder.receive(type: type, event: event); return }
        _ = route(type: type, event: event, passive: true)
    }
    static func synthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) || event.getIntegerValueField(.eventSourceUserData) == 0x4A544B535245504C
    }
    private func escape(type: CGEventType, event: CGEvent) {
        if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            // Defer UI work, but close admission synchronously before any pending action can start.
            generation &+= 1; pendingDispatch.removeAll(); runner.cancelAll(escape: true)
        }
    }
    /// Called first by the shared active tap. Transparent definitions never enter this path.
    func intercept(type: CGEventType, event: CGEvent) -> Bool {
        guard !Self.synthetic(event) else { return false }
        escape(type: type, event: event)
        if passiveTap == nil, let recorder = recorder { recorder.receive(type: type, event: event) }
        return route(type: type, event: event, passive: false)
    }
    private func route(type: CGEventType, event: CGEvent, passive: Bool) -> Bool {
        if [.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].contains(type) {
            return !passive && activeMatcher.absorbsDrag(button: UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber)))
        }
        guard let input = Self.input(type: type, event: event) else { return false }
        let choices = available && !blocksGestures ? eligible.filter { $0.mode == (passive ? .transparent : .absorbing) && ($0.configured || $0.id == testID) } : []
        let tracking = passive ? passiveMatcher.isTracking(input.combination) : activeMatcher.isTracking(input.combination)
        guard tracking || choices.contains(where: { $0.combination == input.combination }) else { return false }
        let own = input.combination.input == .key ? (NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()) : Self.targetsOwnWindow(event.location)
        let hadAbsorbedPress = activeMatcher.hasAbsorbedPress
        let result: ShortcutMatcher.Result
        if passive { result = passiveMatcher.handle(input.combination, down: input.down, repeating: input.repeating, excluded: own, shortcuts: choices) }
        else { result = activeMatcher.handle(input.combination, down: input.down, repeating: input.repeating, excluded: own, shortcuts: choices) }
        if !passive && hadAbsorbedPress && !activeMatcher.hasAbsorbedPress {
            DispatchQueue.main.async { [weak self] in self?.onNeedsReconcile?() }
        }
        if let shortcut = result.activation {
            if shortcut.id == testID {
                testReceived = true
                testResult = "Received \(shortcut.combination?.display ?? "shortcut") (\(shortcut.mode.rawValue)). Other interceptors and protected shortcuts may still take priority."
                DispatchQueue.main.async { [weak self] in self?.changed() }
            } else if !pendingDispatch.contains(shortcut.id) {
                pendingDispatch.insert(shortcut.id); let admittedGeneration = generation
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.pendingDispatch.remove(shortcut.id)
                    guard self.generation == admittedGeneration, self.available, !self.blocksGestures,
                          self.preferences.shortcuts.contains(shortcut) else { return }
                    if self.runner.start(shortcut) {
                        self.executionErrors.removeValue(forKey: shortcut.id)
                        self.errors.removeValue(forKey: shortcut.id); self.changed()
                    }
                }
            }
        }
        return !passive && result.suppress
    }
    static func targetsOwnWindow(_ point: CGPoint) -> Bool {
        // Query the window actually hit, including windows owned by other applications;
        // overlapping rectangles alone cannot establish ownership.
        let screenPoint = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return number > 0 && NSApp.windows.contains { $0.windowNumber == number }
    }
    static func input(type: CGEventType, event: CGEvent, includeLabel: Bool = false) -> (combination: ShortcutCombination, down: Bool, repeating: Bool)? {
        let down = [.keyDown,.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type)
        guard down || [.keyUp,.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(type) else { return nil }
        let keyboard = type == .keyDown || type == .keyUp
        let code = UInt16(clamping: event.getIntegerValueField(keyboard ? .keyboardEventKeycode : .mouseEventButtonNumber))
        return (ShortcutCombination(input: keyboard ? .key : .mouse, code: code, modifiers: event.flags.rawValue,
                                    keyLabel: keyboard && includeLabel ? keyLabel(code: code, fallback: NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? "") : ""), down,
                keyboard && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    }
    private static func keyLabel(code: UInt16, fallback: String) -> String {
        // Translate the hardware key with no modifiers, so Shift+9 displays ⇧ 9 rather
        // than ⇧ (. TIS also respects the selected keyboard layout.
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &length, &characters)
        return status == noErr && length > 0 ? String(utf16CodeUnits: characters, count: length) : fallback
    }
    func record(_ shortcut: ShortcutDefinition, completion: @escaping (ShortcutCombination) -> Void) {
        recorder?.cancel()
        let controller = ShortcutRecorderController(validate: { [weak self] combination in
            guard let self = self else { return "Recorder unavailable." }
            var candidate = shortcut; candidate.combination = combination
            return ShortcutConflictChecker.error(for: candidate, among: self.preferences.shortcuts, gestures: self.preferences.gesture)
        }, completion: { [weak self] combination in
            self?.recorder = nil
            self?.onNeedsReconcile?()
            if let combination = combination { completion(combination) }
        })
        recorder = controller; passiveMatcher.cancelActivations(); activeMatcher.cancelActivations()
        onNeedsReconcile?()
        controller.show()
    }
    func test(_ id: UUID) {
        testID = id; testReportID = id; testReceived = false; testGeneration = UUID(); let token = testGeneration
        testResult = "Switch to another application and press the shortcut within 10 seconds. Actions will not run during this test."
        onNeedsReconcile?(); changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.testGeneration == token else { return }
            if !self.testReceived { self.testResult = "No matching input was received. Check permissions, Secure Keyboard Entry, and earlier interceptors. Jimmy Tweaks cannot guarantee access to protected input." }
            self.testID = nil; self.onNeedsReconcile?(); self.changed()
        }
    }
    func message(for shortcut: ShortcutDefinition) -> String {
        if let error = errors[shortcut.id] { return error }
        if testReportID == shortcut.id { return testResult }
        return errors[shortcut.id] ?? (!shortcut.configured ? "Record a shortcut and add actions to activate it." : "")
    }
    private func showCancellation() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.toastDismiss?.cancel()
            let panel = self.toast ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 54), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.ignoresMouseEvents = true; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            let material = NSVisualEffectView(); material.material = .hudWindow; material.state = .active
            material.wantsLayer = true; material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
            UI.pin(UI.label("Scripts canceled due to Escape key"), in: material, inset: 16); panel.contentView = material
            if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 165, y: screen.visibleFrame.maxY - 100)) }
            self.toast = panel; panel.orderFrontRegardless()
            let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }; self.toastDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }
}

#if TESTING
extension ShortcutController {
    func observeForTesting(type: CGEventType, event: CGEvent) { observe(type: type, event: event) }
}
#endif
