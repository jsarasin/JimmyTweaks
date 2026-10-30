import AppKit

final class PermissionAssistant: NSWindowController, NSWindowDelegate {
    private let context: SettingsContext
    private let body = NSStackView()
    private let progress = UI.caption("")
    private let heading = UI.label("", size: 24, weight: .semibold)
    private let explanation = UI.label("")
    private let status = UI.caption("")
    private var step = 0
    private let back = ActionButton("Back") {}
    private let next = ActionButton("Next") {}
    private let skip = ActionButton("Skip Setup") {}
    private let grant = ActionButton("Enable Accessibility…") {}
    private let settings = ActionButton("Open System Settings") {}
    private let check = ActionButton("Check Again") {}
    private var observer: NSObjectProtocol?
    private var finished = false
    private var focusID: String?

    init(context: SettingsContext) {
        self.context = context
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 435), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Jimmy Tweaks Setup"; window.delegate = self; window.isReleasedWhenClosed = false
        let root = NSView(); window.contentView = root
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 16; body.detachesHiddenViews = true; UI.pin(body, in: root, inset: 26)
        for v in [progress, heading, explanation, status] { body.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        for b in [grant, settings, check] { body.addArrangedSubview(b) }
        let spacer = NSView(); body.addArrangedSubview(spacer); spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        let footer = UI.horizontal([skip, NSView(), back, next]); body.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        next.keyEquivalent = "\r"; skip.keyEquivalent = "\u{1b}"
        back.handler = { [weak self] in guard let self = self else { return }; self.step = max(0, self.step - 1); self.update() }
        next.handler = { [weak self] in guard let self = self else { return }; if self.step == 2 { self.dismiss(skipped: false) } else { self.step += 1; self.update() } }
        skip.handler = { [weak self] in self?.dismiss(skipped: true) }
        grant.handler = { [weak self] in self?.context.permissions.request(); self?.update() }
        settings.handler = { [weak self] in self?.context.permissions.openSettings() }
        check.handler = { [weak self] in self?.context.runtime.retry(); self?.update() }
        observer = NotificationCenter.default.addObserver(forName: .permissionsChanged, object: nil, queue: .main) { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    func present(on parent: NSWindow, requestedStep: Int?, focusID: String?) {
        self.focusID = focusID
        if let requestedStep = requestedStep { step = min(2, max(0, requestedStep)) }
        else if context.preferences.needsAssistant { step = 0 }
        else { step = context.permissions.ready ? 2 : 1 }
        finished = false; update()
        context.permissions.setDetailed("assistant", visible: true)
        guard let window = window else { return }
        if parent.attachedSheet !== window { parent.beginSheet(window) }
        window.makeKeyAndOrderFront(nil)
    }
    private func update() {
        window?.setContentSize(NSSize(width: 600, height: step == 1 ? 590 : 470))
        progress.stringValue = "STEP \(step + 1) OF 3 · PERMISSION ASSISTANT"
        back.isEnabled = step > 0; next.title = step == 2 ? "Finish" : "Next"
        grant.isHidden = step != 1; settings.isHidden = step != 1; check.isHidden = step != 1
        switch step {
        case 0:
            heading.stringValue = "A few small window gestures."
            explanation.stringValue = "Hold Command and right-drag a window corner to resize, or Command and left-drag inside a window to move it. Jimmy Tweaks keeps working in the background after Settings closes. Open it again from Applications to change settings."
            status.stringValue = "Setup is optional. Skip at any time and reopen this assistant from Status or Permissions."
        case 1:
            heading.stringValue = "Allow window control."
            explanation.stringValue = "macOS requires your permission before Jimmy Tweaks can change other apps' window frames and intercept its mouse gestures. In Privacy & Security, find Jimmy Tweaks in the category for controlling other applications and enable it. The exact category name may vary."
            status.stringValue = context.permissions.summary + " Input Monitoring is not required for this capture path. You can continue without granting access."
        default:
            heading.stringValue = "You're in control."
            let p = context.preferences
            explanation.stringValue = "Resizing: \(p.bool(.resizeEnabled) ? "On" : "Off") · Moving: \(p.bool(.moveEnabled) ? "On" : "Off")\nSuspend All: \(p.bool(.suspended) ? "On" : "Off")\n\n\(context.permissions.summary)\n\nReoccurring Scripts is a NONFUNCTIONAL UI STUB. Nothing runs."
            status.stringValue = context.permissions.ready ? "Enabled features activate automatically while Suspend All is off." : "Settings remains usable. Affected features stay inactive until the required access is available."
        }
        let stepID = ["welcome", "accessibility", "review"][step]
        for (name, button) in [("back", back), ("next", next), ("skip", skip), ("request", grant), ("openSettings", settings), ("check", check)] {
            button.identifier = NSUserInterfaceItemIdentifier("assistant.\(stepID).\(name)")
            button.setAccessibilityHelp("Permission assistant: \(button.title). Permission grants remain optional.")
        }
        if let focusID = focusID {
            let buttons = [back, next, skip, grant, settings, check]
            if let button = buttons.first(where: { $0.identifier?.rawValue == focusID && !$0.isHidden && $0.isEnabled }) { window?.makeFirstResponder(button) }
            self.focusID = nil
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(skipped: true); return false }
    private func dismiss(skipped: Bool) {
        guard !finished else { return }; finished = true
        context.preferences.finishAssistant(skipped: skipped); context.permissions.setDetailed("assistant", visible: false)
        if let window = window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
    }
    static func registerMetadata(in catalog: SearchCatalog) {
        for (index, step) in ["welcome", "accessibility", "review"].enumerated() {
            for (action, label) in [("back", "Back"), ("next", index == 2 ? "Finish Setup" : "Next Setup Step"), ("skip", "Skip Setup")] {
                catalog.register(ControlMetadata(id: "assistant.\(step).\(action)", label: label, description: "Navigate the skippable permission assistant. No permission is requested by opening this search result.", keywords: ["assistant", "setup", "onboarding", step], section: "Permission Assistant",
                    destination: SearchDestination(page: .permissions, controlID: "assistant.\(step).\(action)", assistantStep: index)))
            }
        }
        for (action, label) in [("request", "Enable Accessibility"), ("openSettings", "Open Permission System Settings"), ("check", "Check Permission Again")] {
            catalog.register(ControlMetadata(id: "assistant.accessibility.\(action)", label: label, description: "Open the permission step and focus this control. Permission requests require a separate deliberate click.", keywords: ["assistant", "trust", "grant", "accessibility"], section: "Permission Assistant",
                destination: SearchDestination(page: .permissions, controlID: "assistant.accessibility.\(action)", assistantStep: 1)))
        }
    }
}
