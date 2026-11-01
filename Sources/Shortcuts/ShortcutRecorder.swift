import AppKit

private final class ShortcutRecordingPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class ShortcutRecorderController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let representation = UI.label("", size: 28, weight: .medium)
    private let error = UI.caption("")
    private let progress = NSProgressIndicator()
    private let confirm = ActionButton("Use Shortcut") {}
    private let again = ActionButton("Record Again") {}
    private let validate: (ShortcutCombination) -> String?
    private var completion: ((ShortcutCombination?) -> Void)?
    private var candidate: ShortcutCombination?
    private var localMonitor: Any?
    private var escapeBegan: TimeInterval?
    private var timer: Timer?
    private var armed = false
    private let now: () -> TimeInterval
    private let escapeHeld: () -> Bool

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, escapeHeld: @escaping () -> Bool = { CGEventSource.keyState(.hidSystemState, key: 53) }, validate: @escaping (ShortcutCombination) -> String?, completion: @escaping (ShortcutCombination?) -> Void) {
        self.validate = validate; self.completion = completion; self.now = now; self.escapeHeld = escapeHeld
        panel = ShortcutRecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 275), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self; panel.level = .floating; panel.hasShadow = true; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        let material = NSVisualEffectView(); material.material = .popover; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 16; material.layer?.masksToBounds = true
        panel.contentView = material
        representation.alignment = .center; representation.heightAnchor.constraint(greaterThanOrEqualToConstant: 45).isActive = true
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 2; progress.style = .bar; progress.isHidden = true
        error.textColor = .systemRed; error.maximumNumberOfLines = 3
        let cancel = ActionButton("Cancel") { [weak self] in self?.cancel() }
        confirm.handler = { [weak self] in guard let self = self, let candidate = self.candidate else { return }; self.finish(candidate) }
        again.handler = { [weak self] in self?.reset() }
        let content = UI.vertical([UI.label("Record Shortcut", size: 18, weight: .semibold), UI.caption("Press a keyboard shortcut or click a mouse button."), representation, error, UI.caption("Hold Esc for 2 seconds to cancel."), progress, UI.horizontal([cancel, NSView(), again, confirm])], spacing: 10)
        UI.pin(content, in: material, inset: 22)
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        reset()
    }
    deinit { if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor) }; timer?.invalidate() }
    func show() {
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            if let cg = event.cgEvent { self.receive(type: cg.type, event: cg) }
            if event.type == .keyDown || event.type == .keyUp { return nil }
            return event
        }
        // Don't record the click which opened this panel or a button still held from that click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.armed = true }
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tickEscape() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func reset() {
        candidate = nil; representation.stringValue = "Waiting for input…"; error.stringValue = ""
        confirm.isEnabled = false; again.isEnabled = false
    }
    func receive(type: CGEventType, event: CGEvent) {
        guard completion != nil else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if (type == .keyDown || type == .keyUp) && code == 53 {
            if type == .keyDown && escapeBegan == nil { escapeBegan = now(); progress.isHidden = false }
            if type == .keyUp { escapeBegan = nil; progress.doubleValue = 0; progress.isHidden = true }
            return
        }
        guard armed, candidate == nil else { return }
        if type == .flagsChanged {
            representation.stringValue = ShortcutCombination(input: .key, code: 0, modifiers: event.flags.rawValue).display.components(separatedBy: "Key 0").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return
        }
        guard let input = ShortcutController.input(type: type, event: event, includeLabel: true), input.down, !input.repeating else { return }
        if input.combination.input == .mouse {
            // Hit-test the frontmost window and then the panel's actual controls. All other
            // panel space is available for recording, including ordinary left/right clicks.
            let p = NSPoint(x: event.location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y)
            if NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0) == panel.windowNumber,
               let content = panel.contentView {
                var hit = content.hitTest(content.convert(panel.convertPoint(fromScreen: p), from: nil))
                while let current = hit { if current is NSButton || (current as? NSTextField)?.isEditable == true { return }; hit = current.superview }
            }
        }
        let combination = input.combination
        representation.stringValue = combination.display
        if let issue = combination.validationError ?? validate(combination) { error.stringValue = issue; return }
        candidate = combination; error.stringValue = ""; confirm.isEnabled = true; again.isEnabled = true
    }
    private func tickEscape() {
        guard let began = escapeBegan else { return }
        // Polling physical state also resets a hold if the key-up was withheld by macOS.
        guard escapeHeld() else { escapeBegan = nil; progress.isHidden = true; progress.doubleValue = 0; return }
        let held = now() - began; progress.doubleValue = held
        if held >= 2 { cancel() }
    }
    func cancel() { finish(nil) }
    private func finish(_ value: ShortcutCombination?) {
        guard let completion = completion else { return }; self.completion = nil
        if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        timer?.invalidate(); timer = nil; panel.orderOut(nil); completion(value)
    }
    func windowWillClose(_ notification: Notification) { cancel() }
    #if TESTING
    func armForTesting() { armed = true }
    func tickForTesting() { tickEscape() }
    var candidateForTesting: ShortcutCombination? { candidate }
    func confirmForTesting() { if let candidate = candidate { finish(candidate) } }
    #endif
}
