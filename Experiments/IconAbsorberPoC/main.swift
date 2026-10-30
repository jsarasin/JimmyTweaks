import AppKit
import ApplicationServices

let targets = ["app.monitorcontrol.MonitorControl", "com.lujjjh.LinearMouse"]

func value<T>(_ element: AXUIElement, _ name: String) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result as? T
}

struct Item {
    let element: AXUIElement
    let pid: pid_t
    let bundle: String
    let index: Int
    let identifier: String
    let title: String
    let frame: CGRect?
    let actions: [String]
    var summary: String { "\(bundle) pid=\(pid) item=\(index) id=\(identifier) title=\(title) frame=\(String(describing: frame)) actions=\(actions)" }
}

func frame(_ element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?, size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

// Run only on a worker. AX reads can block even when the app is healthy.
func discover(_ bundles: [String]) -> ([Item], [String]) {
    var items: [Item] = [], notes: [String] = []
    for bundle in bundles {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        if apps.isEmpty { notes.append("\(bundle): NOT RUNNING (not launched automatically)") }
        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)
            var extras: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(root, kAXExtrasMenuBarAttribute as CFString, &extras)
            notes.append("\(bundle): pid=\(app.processIdentifier) terminated=\(app.isTerminated) AXExtrasMenuBar error=\(error.rawValue)")
            guard error == .success, let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() else { continue }
            let bar = extras as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, 0.5)
            let children: [AXUIElement] = value(bar, kAXChildrenAttribute) ?? []
            for (index, child) in children.enumerated() {
                AXUIElementSetMessagingTimeout(child, 0.5)
                let role: String = value(child, kAXRoleAttribute) ?? ""
                // Restrict the experiment to actual third-party status items.
                guard role == kAXMenuBarItemRole else { continue }
                var names: CFArray?
                AXUIElementCopyActionNames(child, &names)
                items.append(Item(element: child, pid: app.processIdentifier, bundle: bundle, index: index,
                                  identifier: value(child, kAXIdentifierAttribute) ?? "",
                                  title: value(child, kAXTitleAttribute) ?? value(child, kAXDescriptionAttribute) ?? "(no AX label)",
                                  frame: frame(child), actions: names as? [String] ?? []))
            }
        }
    }
    return (items, notes)
}

func diagnostics() -> [String] {
    ["PROOF OF CONCEPT: UNVERIFIED — API success never implies visual acceptance.",
     "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
     "PID: \(ProcessInfo.processInfo.processIdentifier)",
     "Accessibility trusted: \(AXIsProcessTrusted())",
     "Input posting permitted: \(CGPreflightPostEventAccess())",
     "Running application count: \(NSWorkspace.shared.runningApplications.count)",
     AssessmentAdapter.capabilityReport()]
}

if CommandLine.arguments.contains("--diagnose") {
    diagnostics().forEach { print($0) }
    let (items, notes) = discover(targets)
    (notes + items.map(\.summary)).forEach { print($0) }
    exit(0)
}

final class Probe: NSObject, NSApplicationDelegate {
    let adapter = AssessmentAdapter()
    let worker = DispatchQueue(label: "local.jimmytweaks.iconabsorber.probe.ax")
    let choices = NSPopUpButton()
    let logView = NSTextView()
    let status = NSTextField(wrappingLabelWithString: "UNVERIFIED — requires real visual and functional checks.")
    var window: NSWindow!
    var items: [Item] = []
    var held = false
    var busy = false
    var generation: UInt64 = 0
    var expiry: Timer?
    var observations: [NSObjectProtocol] = []
    var runningObservation: NSKeyValueObservation?
    var buttons: [NSButton] = []

    func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        print(line, terminator: ""); fflush(stdout)
        logView.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
        logView.scrollToEndOfDocument(nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 930, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Icon Absorber — Phase 1 Probe (UNVERIFIED)"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        stack.addArrangedSubview(status)
        let warning = NSTextField(wrappingLabelWithString: "Private assessment API experiment. Other Apple modules and Notification Center may be affected. Every hide is limited to 60 seconds. Restore All releases the assertion. No test is automatically marked passed.")
        stack.addArrangedSubview(warning)
        choices.addItem(withTitle: "Discover MonitorControl / LinearMouse first")
        stack.addArrangedSubview(choices)
        addRow(stack, [("Discover", #selector(scan)), ("Hide selected app (60 s)", #selector(hide)), ("Restore All", #selector(restore)), ("Crash while hidden", #selector(crash))])
        addRow(stack, [("Original AXPress", #selector(press)), ("Simulated left click", #selector(left)), ("Simulated right click", #selector(right)), ("Re-hide after closing UI", #selector(hide))])
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Invocation releases the restriction, waits for a freshly located item, then invokes the original app. Close its UI and choose Re-hide. Save the log before crashing; observe recovery without reopening either app."))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = logView
        logView.isEditable = false; logView.isVerticallyResizable = true; logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        stack.addArrangedSubview(scroll)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        let menu = NSMenu(); let entry = NSMenuItem(); menu.addItem(entry); let appMenu = NSMenu(); entry.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        diagnostics().forEach(log)
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                // Fail open rather than accidentally hide a new unselected process.
                if self?.held == true || self?.busy == true { self?.release("Running application list changed; fail-open release.") }
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.release("Session changed; released.") })
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        scan()
    }
    func addRow(_ stack: NSStackView, _ actions: [(String, Selector)]) {
        let row = NSStackView(); row.spacing = 8
        for (title, action) in actions {
            let button = NSButton(title: title, target: self, action: action)
            row.addArrangedSubview(button); buttons.append(button)
        }
        stack.addArrangedSubview(row)
    }
    func selected() -> Item? {
        guard items.indices.contains(choices.indexOfSelectedItem) else { return nil }
        return items[choices.indexOfSelectedItem]
    }
    @objc func scan() {
        guard !busy else { return }
        release("Discovery starts with restriction released.")
        let token = generation
        busy = true
        worker.async { [weak self] in
            let result = discover(targets)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.busy = false; self.items = result.0; self.choices.removeAllItems()
                for item in self.items { self.choices.addItem(withTitle: "\(item.bundle) — item \(item.index): \(item.title)") }
                if self.items.isEmpty { self.choices.addItem(withTitle: "No accessible target items — see log") }
                (result.1 + self.items.map(\.summary)).forEach(self.log)
            }
        }
    }
    @objc func hide() {
        guard !busy, let item = selected(), AXIsProcessTrusted() else { log("Hide refused: discover a target and grant Accessibility to this probe first."); return }
        release("Preparing hide.")
        guard targets.contains(item.bundle), !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundle).isEmpty else { log("Target no longer running; rediscover."); return }
        let apps = NSWorkspace.shared.runningApplications
        guard !apps.isEmpty else { log("Hide refused: running-app list unavailable."); return }
        let allowed = Set(apps.compactMap(\.bundleIdentifier)).union([Bundle.main.bundleIdentifier ?? "local.jimmytweaks.iconabsorber.probe"]).subtracting([item.bundle])
        log("Request hiding ONLY \(item.bundle); keeping \(allowed.count) running bundles and system IDs 0...8. Inspect unrelated controls now.")
        busy = true; let token = generation
        // Includes activation timeout; no callback can leave a restriction held forever.
        expiry = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.release("60-second expiry; released.") }
        adapter.activateAllowingBundles(allowed.sorted()) { [weak self] error in
            guard let self, self.generation == token else { return }
            self.busy = false
            if let error { self.release("Activation failed: \(error)"); return }
            self.held = true
            self.status.stringValue = "ASSERTION ACCEPTED — visually verify hidden item and unrelated controls; overall UNVERIFIED."
            self.log("API activation completed without error. Hiding, app health and isolation remain UNVERIFIED by this callback.")
            self.log("Target still registered: \(NSRunningApplication(processIdentifier: item.pid)?.isTerminated == false)")
        }
    }
    func release(_ reason: String) {
        generation &+= 1; adapter.invalidate(); expiry?.invalidate(); expiry = nil; held = false; busy = false
        status.stringValue = "Restriction released — visually check restoration. Overall UNVERIFIED."
        log(reason)
    }
    @objc func restore() { release("Restore All requested; invalidate called. Verify actual visibility.") }
    @objc func press() { invoke(mode: "AXPress") }
    @objc func left() { invoke(mode: "left") }
    @objc func right() { invoke(mode: "right") }
    func invoke(mode: String) {
        guard !busy, let original = selected() else { return }
        release("Invocation \(mode): temporarily restoring physical item; no UI reconstruction.")
        busy = true; let token = generation
        worker.async { [weak self] in
            var previous: CGRect?, target: Item?
            // Bounded settling reads, not a permanent polling loop. No stale hidden coordinates.
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.15)
                let (found, _) = discover([original.bundle])
                guard let fresh = found.first(where: { $0.pid == original.pid && $0.index == original.index && $0.identifier == original.identifier }),
                      let rect = fresh.frame, rect.width > 0, rect.height > 0 else { continue }
                if rect == previous { target = fresh; break }
                previous = rect
            }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                guard let target else { self.busy = false; self.log("No fresh settled item; invocation aborted."); return }
                self.log("Fresh invocation target: \(target.summary)")
                if mode == "AXPress" {
                    self.worker.async {
                        AXUIElementSetMessagingTimeout(target.element, 3)
                        let result = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
                        DispatchQueue.main.async {
                            guard token == self.generation else { return }
                            self.busy = false
                            self.log("AXPress result=\(result.rawValue); a timeout can accompany an open native menu. Verify the actual interface and slider manually.")
                        }
                    }
                } else {
                    self.busy = false
                    self.click(target, right: mode == "right")
                }
            }
        }
    }
    func click(_ target: Item, right: Bool) {
        guard CGPreflightPostEventAccess(), let rect = target.frame else { log("Input posting unavailable; no events sent. Grant Accessibility and relaunch."); return }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        // Reject overflow or stale geometry that hits a different owner's item.
        var hit: AXUIElement?
        let root = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success, let hit else { log("Hit test unavailable; no click sent."); return }
        var owner: pid_t = 0; AXUIElementGetPid(hit, &owner)
        guard owner == target.pid else { log("Hit-test owner \(owner) differs from target \(target.pid); no click sent. Use AXPress; simulated click remains UNVERIFIED."); return }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left) else { log("Could not allocate click events."); return }
        down.setIntegerValueField(.mouseEventClickState, value: 1); up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        log("\(right ? "Right" : "Left") click posted at \(point). Inspect original UI; event posting is not evidence of acceptance. Restriction stays released until Re-hide.")
    }
    @objc func crash() {
        guard held else { log("Crash test refused: no accepted hiding assertion. Hide and visually confirm first."); return }
        log("Deliberate SIGKILL now; no invalidate, termination handler or watchdog. Verify icon returns and owner PID stays unchanged.")
        kill(getpid(), SIGKILL)
    }
    func applicationWillTerminate(_ notification: Notification) { adapter.invalidate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Probe()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
