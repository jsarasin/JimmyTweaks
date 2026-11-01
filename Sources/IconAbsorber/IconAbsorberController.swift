import AppKit
import ApplicationServices

final class IconAbsorberController {
    let preferences: PreferenceStore
    let permissions: PermissionCoordinator
    private let logger: FileLogger
    private let service = IconAssertionClient()
    private let worker = DispatchQueue(label: "JimmyTweaks.iconAbsorber.accessibility", qos: .userInitiated)
    private let scanItems: () -> StatusItemSnapshot
    private(set) var items: [AbsorbedStatusItem] = []
    private(set) var images: [String: NSImage] = [:]
    private(set) var state = "Disabled"
    private(set) var detail = "Choose applications to absorb their menu bar items."
    private(set) var failure: String?
    private(set) var capturing = false
    private(set) var snapshot = StatusItemSnapshot()
    private var observations: [NSObjectProtocol] = []
    private var runningObservation: NSKeyValueObservation?
    private var itemObservations: [StatusItemObservation] = []
    private var scanWork: DispatchWorkItem?
    private var scanRevision: UInt64 = 0
    private var scanInFlight = false
    private var scanned = false
    private var scanAgain = false
    private var maintenance: Timer?
    private var panelVisible = false
    private var sessionActive = true
    private var intent = ""
    private var lastHidden: Set<String>?
    private var applyRevision: UInt64 = 0
    private var temporaryAllowed = Set<String>()
    private var pausedForInteraction = false
    private var interaction: AbsorbedStatusItem?
    private var interactionRevision: UInt64 = 0
    private var interactionGate: Locked<Bool>?
    private var interactionTimer: Timer?
    private var interactionStarted = Date()
    private var interactionBaseline = Set<CGWindowID>()
    private var menuOpen = false
    private var sawSurface = false
    private var quietTicks = 0
    private var pressReturned = false
    private var panelPositioned = false
    private var axWindowsBefore: [AXUIElement] = []
    private var invocationAnchor: CGPoint?
    private var invocationScreen = CGRect.zero
    private var clockMonitor: Any?
    private var stopped = false
    private var wasActive = false

    init(preferences: PreferenceStore, permissions: PermissionCoordinator, logger: FileLogger, scanItems: @escaping () -> StatusItemSnapshot = StatusItemAccess.scan) {
        self.preferences = preferences; self.permissions = permissions; self.logger = logger
        self.scanItems = scanItems
        service.onFailure = { [weak self] message in self?.fail(message) }
        observations.append(NotificationCenter.default.addObserver(forName: .preferencesChanged, object: preferences, queue: .main) { [weak self] _ in self?.reconcile() })
        observations.append(NotificationCenter.default.addObserver(forName: .permissionsChanged, object: permissions, queue: .main) { [weak self] _ in self?.permissionsDidChange() })
        let workspace = NSWorkspace.shared
        runningObservation = workspace.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applicationsChanged() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observations.append(workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sessionActive = false; self?.reconcile(force: true) })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observations.append(workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sessionActive = true; self?.refresh() })
        }
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.images = [:]; self?.cancelInteraction(); self?.refresh()
        })
        reconcile()
    }
    var enabled: Bool { preferences.bool(.iconAbsorberEnabled) }
    var selectedBundles: [String] { preferences.iconAbsorberSelection.bundles }
    var absorbedItems: [AbsorbedStatusItem] { selectedBundles.flatMap { bundle in items.filter { $0.bundle == bundle }.sorted { $0.index < $1.index } } }
    var isHolding: Bool { service.held }
    var canInvokeStatusItems: Bool { active && !capturing && snapshot.unsupportedSystemItems.isEmpty }
    func isAbsorbed(_ bundle: String) -> Bool { service.held && selectedBundles.contains(bundle) && !temporaryAllowed.contains(bundle) }
    var active: Bool { enabled && !preferences.bool(.suspended) && sessionActive && permissions.accessibility && failure == nil && !stopped }
    var applicationListMessage: String? {
        if !permissions.accessibility { return "Allow Jimmy Tweaks using General → Open System Settings to discover running menu bar applications." }
        if scanInFlight || !scanned { return "Looking for running applications with menu bar items…" }
        if items.isEmpty { return "No accessible menu bar applications found. Start an application such as MonitorControl, then choose Refresh." }
        return nil
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible; permissions.setDetailed("icon-absorber", visible: visible)
        if visible { refresh() }; scheduleMaintenance()
    }
    func select(_ bundle: String, selected: Bool) {
        guard bundle != Bundle.main.bundleIdentifier, !bundle.hasPrefix("com.apple.") else { return }
        var selection = preferences.iconAbsorberSelection; selection.select(bundle, selected: selected)
        preferences.iconAbsorberSelection = selection
    }
    func move(_ bundle: String, before next: String?) {
        var selection = preferences.iconAbsorberSelection; selection.move(bundle, before: next)
        preferences.iconAbsorberSelection = selection
    }
    func restoreAll() { preferences.set(false, for: .iconAbsorberEnabled) }
    func retry() { failure = nil; scanned = false; pausedForInteraction = false; reconcile(force: true); refresh() }
    func refresh() {
        guard !stopped else { return }
        if pausedForInteraction { pausedForInteraction = false }
        permissions.refresh()
        reconcile(force: true); scheduleScan()
    }
    private func changed() { NotificationCenter.default.post(name: .iconAbsorberChanged, object: self) }
    private func permissionsDidChange() {
        guard !stopped else { return }
        if !permissions.accessibility {
            scanRevision &+= 1; scanWork?.cancel(); scanInFlight = false; scanAgain = false; scanned = false
            items = []; images = [:]; snapshot = StatusItemSnapshot(); itemObservations = []
        }
        reconcile(force: true)
        if permissions.accessibility { scheduleScan() }
        changed()
    }
    private func setState(_ state: String, _ detail: String) {
        guard self.state != state || self.detail != detail else { return }
        self.state = state; self.detail = detail; changed()
    }
    private func reconcile(force: Bool = false) {
        guard !stopped else { return }
        let signature = "\(enabled)/\(preferences.bool(.suspended))/\(sessionActive)/\(permissions.accessibility)/\(selectedBundles)/\(preferences.bool(.iconAbsorberHiddenPress))"
        guard force || signature != intent else { return }
        if !enabled { failure = nil }
        if active && !wasActive { scanned = false }
        wasActive = active
        intent = signature
        cancelInteraction(); lastHidden = nil; applyRevision &+= 1
        if !active {
            service.stop(); stopClockMonitor()
            if !enabled { setState("Disabled", "Selected applications remain saved. All original items are restored.") }
            else if preferences.bool(.suspended) || !sessionActive { setState("Paused", "All original items are restored while Jimmy Tweaks is suspended or this session is inactive.") }
            else if !permissions.accessibility { setState("Permission Required", "Allow Jimmy Tweaks Accessibility access to discover and invoke original status items.") }
            else { setState("Unavailable", failure ?? "The visibility service is unavailable.") }
        } else if !scanned {
            setState("Discovering", "Looking for applications with menu bar items…"); scheduleScan()
        } else { applyVisibility() }
        scheduleMaintenance()
    }
    private func scheduleMaintenance() {
        maintenance?.invalidate(); maintenance = nil
        guard !stopped, panelVisible || enabled else { return }
        // Some apps do not publish AX item-creation notifications. This low-frequency
        // fallback complements process and AX events, and stops when unused.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }; self.permissions.refresh(); self.scheduleScan()
        }
        timer.tolerance = 2; RunLoop.main.add(timer, forMode: .common); maintenance = timer
    }
    private func applicationsChanged() {
        guard panelVisible || enabled else { return }
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        for item in items where !running.contains(item.pid) { images.removeValue(forKey: item.id) }
        items.removeAll { !running.contains($0.pid) }
        if let interaction, !running.contains(interaction.pid) { cancelInteraction(); applyVisibility() }
        changed(); scheduleScan()
    }
    private func scheduleScan() {
        guard permissions.accessibility, panelVisible || enabled, !stopped else { return }
        if scanInFlight { scanAgain = true; return }
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }; scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private func scan() {
        guard !scanInFlight, !stopped else { return }
        scanInFlight = true; scanRevision &+= 1; let revision = scanRevision
        let scanItems = self.scanItems
        worker.async { [weak self] in
            let result = scanItems()
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.scanRevision == revision else { return }
                self.scanInFlight = false; self.scanned = true; self.snapshot = result
                let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                let found = Set(result.items.map(\.id))
                let remembered = self.items.filter { !found.contains($0.id) && running.contains($0.pid) && self.selectedBundles.contains($0.bundle) && self.service.held }
                self.items = result.items + remembered
                let ids = Set(self.items.map(\.id)); self.images = self.images.filter { ids.contains($0.key) }
                self.observeItems(); self.applyVisibility(); self.changed()
                if self.scanAgain { self.scanAgain = false; self.scheduleScan() }
            }
        }
    }
    private func observeItems() {
        itemObservations = Dictionary(grouping: items, by: \.pid).map { pid, group in
            StatusItemObservation(pid: pid, items: group) { [weak self] name, element in
                guard let self else { return }
                if name == kAXUIElementDestroyedNotification {
                    for item in self.items where CFEqual(item.element, element) { self.images.removeValue(forKey: item.id) }
                    self.items.removeAll { CFEqual($0.element, element) }; self.changed()
                }
                if self.interaction?.pid == pid {
                    if name == kAXMenuOpenedNotification { self.menuOpen = true; self.sawSurface = true }
                    if name == kAXMenuClosedNotification { self.menuOpen = false; self.finishInteraction() }
                }
                if name != kAXMenuOpenedNotification { self.scheduleScan() }
            }
        }
    }
    private func applyVisibility(completion: ((Bool) -> Void)? = nil) {
        guard active, !capturing else { completion?(false); return }
        guard !pausedForInteraction else { completion?(false); return }
        let running = Set(items.map(\.bundle))
        let hidden = Set(selectedBundles).intersection(running).subtracting(temporaryAllowed)
        if !hidden.isEmpty && !snapshot.unsupportedSystemItems.isEmpty {
            applyRevision &+= 1; lastHidden = nil; service.stop(); stopClockMonitor()
            setState("Compatibility Pause", "All items are restored because this menu bar contains Apple controls the visibility API cannot preserve: " + snapshot.unsupportedSystemItems.joined(separator: ", ") + ".")
            completion?(false); return
        }
        guard lastHidden != hidden || completion != nil else { return }
        lastHidden = hidden; applyRevision &+= 1; let revision = applyRevision
        if hidden.isEmpty, temporaryAllowed.isEmpty {
            service.stop(); stopClockMonitor()
            setState("Ready", selectedBundles.isEmpty ? "Select applications below to absorb their status items." : "Waiting for your selected applications to provide status items.")
            completion?(true); return
        }
        service.apply(hidden: hidden.sorted()) { [weak self] result in
            guard let self, self.applyRevision == revision, self.active else { return }
            switch result {
            case .success(let held):
                self.setState(self.interaction == nil ? "Enabled" : "Controls Open", self.interaction == nil ? "\(hidden.count) application(s) absorbed. Click an icon in the desktop preview to open its original controls." : "Using the owning application's original interface. Its icon is hidden again when those controls close.")
                if held { self.startClockMonitor() } else { self.stopClockMonitor() }
                completion?(true)
            case .failure(let error): self.fail(error.localizedDescription); completion?(false)
            }
        }
    }
    private func fail(_ message: String) {
        guard failure != message, !stopped else { return }
        failure = message; cancelInteraction(); lastHidden = nil; service.stop(); stopClockMonitor()
        setState("Unavailable", message)
        logger.log("iconAbsorber", "visibility.failure", message, severity: "WARN")
    }
    func activate(_ item: AbsorbedStatusItem, rightClick: Bool = false, anchor: CGPoint? = nil, visibleFrame: CGRect = .zero) {
        guard active, !capturing, selectedBundles.contains(item.bundle), snapshot.unsupportedSystemItems.isEmpty else { return }
        beginInteraction(item, rightClick: rightClick, anchor: anchor, visibleFrame: visibleFrame)
    }
    private func beginInteraction(_ item: AbsorbedStatusItem, rightClick: Bool, anchor: CGPoint?, visibleFrame: CGRect, clock: Bool = false) {
        cancelInteraction(); pausedForInteraction = false
        interaction = item; interactionStarted = Date(); invocationAnchor = anchor; invocationScreen = visibleFrame
        interactionBaseline = Set(StatusItemAccess.surfaces().map(\.id)); let revision = interactionRevision
        let direct = !rightClick && !clock && preferences.bool(.iconAbsorberHiddenPress)
        let gate = Locked(true); interactionGate = gate
        func invoke(_ target: AbsorbedStatusItem) {
            guard revision == self.interactionRevision else { return }
            self.startInteractionTimer()
            self.worker.async { [weak self] in
                guard gate.snapshot else { return }
                let root = AXUIElementCreateApplication(target.pid); AXUIElementSetMessagingTimeout(root, 0.25)
                let before: [AXUIElement] = StatusItemAccess.value(root, kAXWindowsAttribute) ?? []
                let result: AXError
                if rightClick { result = Self.rightClick(target) }
                else {
                    AXUIElementSetMessagingTimeout(target.element, 3)
                    result = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
                }
                DispatchQueue.main.async {
                    guard let self, revision == self.interactionRevision else { return }
                    self.axWindowsBefore = before; self.pressReturned = true
                    if result != .success && result != .cannotComplete {
                        self.setState("Item Unavailable", "The application did not accept this action (Accessibility error \(result.rawValue)). Try refreshing the application list.")
                        self.finishInteraction()
                    }
                }
            }
        }
        if direct {
            setState("Opening Controls", "Trying AXPress while the icon remains hidden. Some applications require temporary restoration.")
            invoke(item)
        } else {
            temporaryAllowed = clock ? Set(selectedBundles) : [item.bundle]
            applyVisibility { [weak self] ok in
                guard let self, revision == self.interactionRevision else { return }
                guard ok else { self.cancelInteraction(); return }
                self.worker.async {
                    var previous: CGRect?, settled: AbsorbedStatusItem?
                    for _ in 0..<12 {
                        guard gate.snapshot else { return }
                        Thread.sleep(forTimeInterval: 0.125)
                        guard let app = NSRunningApplication(processIdentifier: item.pid),
                              let fresh = StatusItemAccess.items(in: app).first(where: { $0.id == item.id }), let rect = fresh.frame, rect.width > 0 else { continue }
                        if previous == rect { settled = fresh; break }; previous = rect
                    }
                    DispatchQueue.main.async {
                        guard revision == self.interactionRevision else { return }
                        guard let settled else { self.finishInteraction(); self.setState("Item Unavailable", "The original icon could not be located after restoration."); return }
                        if clock, let centerPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier {
                            let alreadyOpen = StatusItemAccess.surfaces().filter { $0.pid == centerPID && $0.frame.width > 200 && $0.frame.height > 30 }
                            if !alreadyOpen.isEmpty {
                                self.interactionBaseline.subtract(alreadyOpen.map(\.id)); self.sawSurface = true; self.pressReturned = true; self.startInteractionTimer(); return
                            }
                        }
                        invoke(settled)
                    }
                }
            }
        }
    }
    private static func rightClick(_ item: AbsorbedStatusItem) -> AXError {
        if item.actions.contains(kAXShowMenuAction) { return AXUIElementPerformAction(item.element, kAXShowMenuAction as CFString) }
        guard CGPreflightPostEventAccess(), let rect = item.frame else { return .notImplemented }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let root = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(root, 0.25)
        var hit: AXUIElement?, pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success, let hit,
              AXUIElementGetPid(hit, &pid) == .success, pid == item.pid else { return .invalidUIElement }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else { return .failure }
        for event in [down, up] { event.setIntegerValueField(.mouseEventClickState, value: 1); event.postToPid(item.pid) }
        return .success
    }
    private func startInteractionTimer() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkInteraction() }
        RunLoop.main.add(timer, forMode: .common); interactionTimer = timer
    }
    private func checkInteraction() {
        guard let item = interaction else { return }
        let clock = item.bundle == "com.apple.MenuBarAgent"
        let centerPID = clock ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier : nil
        let surfaces = StatusItemAccess.surfaces().filter { !interactionBaseline.contains($0.id) && ($0.pid == item.pid || $0.pid == centerPID) && $0.frame.width > 40 && $0.frame.height > 25 }
        let open = menuOpen || !surfaces.isEmpty
        if open { sawSurface = true; quietTicks = 0 }
        else if pressReturned { quietTicks += 1 }
        if !clock, open, !panelPositioned, pressReturned, preferences.bool(.iconAbsorberPositionPanels), let anchor = invocationAnchor {
            panelPositioned = true; let baseline = axWindowsBefore; let visible = invocationScreen; let gate = interactionGate
            worker.async { StatusItemAccess.repositionFloatingPanel(pid: item.pid, excluding: baseline, near: anchor, within: visible, stillValid: { gate?.snapshot == true }) }
        }
        if !open, pressReturned, (sawSurface && quietTicks >= 2 || !sawSurface && Date().timeIntervalSince(interactionStarted) > 2) {
            let detected = sawSurface; finishInteraction()
            if !detected { setState("Enabled", "No original menu or panel was detected. If this item requires restoration, turn off ‘Keep icons hidden when opening controls’. Right-click support varies by application.") }
        } else if Date().timeIntervalSince(interactionStarted) > 120 {
            // Never tear down a long-lived original interface just to reclaim its icon.
            cancelInteraction(); applyRevision &+= 1; service.stop(); lastHidden = nil; pausedForInteraction = true
            setState("Paused for Controls", "The original interface is still open. All icons are restored; choose Refresh after closing it to resume absorption.")
        }
    }
    private func finishInteraction() { cancelInteraction(); lastHidden = nil; applyVisibility() }
    private func cancelInteraction() {
        interactionRevision &+= 1; interactionGate?.withValue { $0 = false }; interactionGate = nil
        interactionTimer?.invalidate(); interactionTimer = nil; interaction = nil; temporaryAllowed = []
        menuOpen = false; sawSurface = false; quietTicks = 0; pressReturned = false; panelPositioned = false
    }
    private func startClockMonitor() {
        guard clockMonitor == nil else { return }
        clockMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.interaction == nil, self.service.held, let clock = self.snapshot.clock, let rect = clock.frame,
                  let primaryHeight = NSScreen.screens.first?.frame.height else { return }
            let mouse = NSEvent.mouseLocation, point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
            guard rect.contains(point) else { return }
            // Release assessment restrictions for the user's explicit clock interaction.
            self.beginInteraction(clock, rightClick: false, anchor: nil, visibleFrame: .zero, clock: true)
        }
    }
    private func stopClockMonitor() { if let clockMonitor { NSEvent.removeMonitor(clockMonitor) }; clockMonitor = nil }
    func refreshPictures() {
        guard !capturing, interaction == nil, permissions.accessibility else { return }
        guard CGPreflightScreenCaptureAccess() else { setState(state, "Allow Screen Recording in System Settings to capture the actual status-item pictures. Application icons are used until then."); return }
        capturing = true; applyRevision &+= 1; service.stop(); lastHidden = nil; changed()
        let revision = interactionRevision
        worker.async { [weak self] in
            Thread.sleep(forTimeInterval: 0.35)
            let first = StatusItemAccess.scan(); Thread.sleep(forTimeInterval: 0.15); let second = StatusItemAccess.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.stopped, revision == self.interactionRevision else {
                    self.capturing = false; self.applyVisibility(); self.changed(); return
                }
                let previous = Dictionary(first.items.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
                let stable = second.items.filter { previous[$0.id] == $0.frame && $0.frame != nil && self.selectedBundles.contains($0.bundle) }
                StatusItemPictures.capture(stable, knownItems: second.items + second.systemItems) { [weak self] pictures in
                    guard let self else { return }; self.capturing = false
                    guard !self.stopped else { return }
                    self.images.merge(pictures, uniquingKeysWith: { _, new in new }); self.lastHidden = nil; self.applyVisibility(); self.changed()
                }
            }
        }
    }
    func shutdown() {
        stopped = true; cancelInteraction(); service.stop(); stopClockMonitor(); maintenance?.invalidate(); scanWork?.cancel(); itemObservations = []
        runningObservation = nil
        observations.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }; observations = []
    }
    deinit { shutdown() }
}
