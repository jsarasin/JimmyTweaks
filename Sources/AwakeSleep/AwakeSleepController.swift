import AppKit

extension Notification.Name { static let awakeSleepChanged = Notification.Name("JimmyTweaks.awakeSleepChanged") }

/// Main-thread owner of the desired session. Backend transitions are serialized; stale
/// acquisitions are released before a replacement starts and can never fire a power action.
final class AwakeSleepController {
    private static let helperSetupFailedKey = WorkerLifecycle.setupFailedKey
    let preferences: PreferenceStore
    private let backend: PowerBackend
    private let logger: FileLogger
    private let now: () -> TimeInterval
    private(set) var session: PowerSession?
    private(set) var error: String?
    private var active: PowerSession?
    private var busy = false
    private var stopped = false
    private var executing = false
    private var intent: UInt64 = 0
    private var lastRenewal: TimeInterval = 0
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cleanupCompletions: [(Result<Void, Error>) -> Void] = []
    private var warning: NSPanel?
    private var warningLabel: NSTextField?
    private let showsWarnings: Bool
    private let presentHelperFailure: (NSAlert) -> Void
    var helperSetupFailed: Bool { preferences.defaults.bool(forKey: Self.helperSetupFailedKey) || backend.helperDisabledUntilReset }
    var helperAvailable: Bool { !helperSetupFailed && backend.helperAvailable }
    var canConfigureHelper: Bool { !helperSetupFailed && backend.canConfigureHelper }
    var powerActionsAllowed: Bool { backend.powerActionsAllowed }
    var helperNeedsApproval: Bool { backend.helperNeedsApproval && !helperSetupFailed }
    var helperStatus: String {
        if backend.helperDisabledUntilReset {
            return backend.helperStatus + " Use Reset Permissions and Uninstall Workers to clear disablement."
        }
        return helperSetupFailed && backend.powerActionsAllowed
            ? "Closed-lid support is disabled after a setup failure. Use Reset Permissions and Uninstall Workers to clear it. Ordinary keep-awake remains available."
            : backend.helperStatus
    }
    var remaining: TimeInterval? { session?.remaining(at: now()) }
    var transitioning: Bool { busy || executing }
    var summary: String {
        if executing { return "Requesting shutdown…" }
        guard let session else { return busy ? "Restoring sleep settings…" : "No active session" }
        let name = session.action == .keepAwake ? "Keeping awake" : session.action == .sleep ? "Sleep" : "Shut down"
        guard let remaining else { return name + " indefinitely" }
        let seconds = max(0, Int(ceil(remaining)))
        return String(format: "%@ in %d:%02d:%02d", name, seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    init(preferences: PreferenceStore, logger: FileLogger, backend: PowerBackend = SystemPowerBackend(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticTimer: Bool = true,
         observeSystem: Bool = true, showsWarnings: Bool = true,
         presentHelperFailure: @escaping (NSAlert) -> Void = { alert in
             // Leave menu tracking before presenting the application-modal dialog.
             DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true); alert.runModal() }
         }) {
        self.preferences = preferences; self.logger = logger; self.backend = backend; self.now = now; self.showsWarnings = showsWarnings
        self.presentHelperFailure = presentHelperFailure
        if observeSystem {
            observe(.default, .preferencesChanged, object: preferences) { [weak self] in self?.preferencesChanged() }
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observe(workspace, name) { [weak self] in self?.cancel() }
            }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.cancel() }
            observe(.default, NSApplication.didBecomeActiveNotification) { [weak self] in
                self?.backend.refreshRecoveryState { [weak self] in self?.changed() }; self?.changed()
            }
        }
        if automaticTimer {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.1; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil, action: @escaping () -> Void) {
        observers.append((center, center.addObserver(forName: name, object: object, queue: .main) { _ in action() }))
    }
    private func changed() { NotificationCenter.default.post(name: .awakeSleepChanged, object: self) }
    private func report(_ failure: Error) {
        error = failure.localizedDescription
        logger.log("awake-sleep", "failure", error!, severity: "WARN"); changed()
    }
    func configureHelper() {
        guard canConfigureHelper else { return }
        do { try backend.configureHelper(); error = nil; changed() }
        catch {
            let failure = error as? PowerHelperFailure
            if failure == nil || failure?.untilReset == true {
                preferences.defaults.set(true, forKey: Self.helperSetupFailedKey)
            }
            logger.log("awake-sleep", "helper-setup-failed", error.localizedDescription, severity: "WARN")
            changed()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Closed-Lid Support Unavailable"
            alert.informativeText = error.localizedDescription + (helperSetupFailed
                ? "\n\nClosed-lid support is permanently disabled until Reset Permissions and Uninstall Workers succeeds. Jimmy Tweaks will not retry setup, including after restarting the app. Ordinary keep-awake sessions are available once sleep restoration is confirmed."
                : "\n\nUse the recovery instructions above. Other Jimmy Tweaks features remain available.")
            alert.addButton(withTitle: "OK")
            presentHelperFailure(alert)
        }
    }
    func start(_ action: PowerAction, duration: TimeInterval?) {
        guard !stopped, !executing, powerActionsAllowed, !preferences.bool(.suspended) else { return }
        guard let duration else {
            guard action == .keepAwake else { return }
            replace(PowerSession(id: UUID(), action: action, deadline: nil, duration: nil)); return
        }
        guard duration.isFinite, duration >= 60, duration <= Double(Int64.max / 1_000_000_000), (now() + duration).isFinite else {
            report(AwakeSleepError.message("Enter a positive duration of at least one minute.")); return
        }
        replace(PowerSession(id: UUID(), action: action, deadline: now() + duration, duration: duration))
    }
    private func replace(_ next: PowerSession) {
        intent &+= 1
        error = nil; dismissWarning(); session = next
        logger.log("awake-sleep", "start", next.action.title + "; seconds=" + (next.duration.map { String($0) } ?? "indefinite"))
        reconcile(); changed()
    }
    func cancel(completion: ((Result<Void, Error>) -> Void)? = nil) {
        intent &+= 1
        if let completion { cleanupCompletions.append(completion) }
        session = nil; executing = false; dismissWarning(); reconcile(); changed()
    }
    private func reconcile() {
        guard !busy else { return }
        if let active, active.id != session?.id {
            busy = true
            backend.end { [weak self] result in
                guard let self else { return }
                self.busy = false; self.active = nil
                if case .failure(let error) = result {
                    self.session = nil; self.report(error); self.finishCleanup(result); self.changed(); return
                }
                self.finishCleanup(.success(()))
                self.reconcile(); self.changed()
            }
            return
        }
        if active == nil, let desired = session {
            busy = true
            backend.begin(session: desired.id, closedLid: helperAvailable, display: preferences.bool(.keepDisplayAwake)) { [weak self] result in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success:
                    self.active = desired; self.lastRenewal = self.now()
                    do { try self.backend.setDisplayAwake(self.preferences.bool(.keepDisplayAwake)) }
                    catch { self.session = nil; self.report(error) }
                case .failure(let error): self.session = nil; self.report(error); self.finishCleanup(.failure(error))
                }
                self.reconcile(); self.changed()
            }
        } else if session == nil { finishCleanup(.success(())) }
    }
    private func finishCleanup(_ result: Result<Void, Error>) {
        let completions = cleanupCompletions; cleanupCompletions.removeAll()
        completions.forEach { $0(result) }
    }
    private func preferencesChanged() {
        if preferences.bool(.suspended) { cancel(); return }
        guard active != nil, !busy else { return }
        do { try backend.setDisplayAwake(preferences.bool(.keepDisplayAwake)) } catch { report(error); cancel() }
    }
    func tick() {
        if !powerActionsAllowed {
            backend.refreshRecoveryState { [weak self] in self?.changed() }
        }
        guard !stopped, let session, active?.id == session.id, !busy else { return }
        let remaining = session.remaining(at: now())
        if !executing, let remaining, remaining <= 0 {
            if session.action == .keepAwake { cancel() }
            else { complete(session) }
            return
        }
        if !executing, let remaining, remaining <= 30, session.action != .keepAwake { showWarning(session, seconds: Int(ceil(remaining))) }
        if now() - lastRenewal >= 5 {
            lastRenewal = now(); busy = true
            backend.renew { [weak self] result in
                guard let self else { return }
                self.busy = false
                if case .failure(let error) = result { self.report(error); self.session = nil; self.dismissWarning() }
                self.reconcile(); self.changed()
            }
        }
        changed()
    }
    private func complete(_ target: PowerSession) {
        dismissWarning()
        if target.action == .sleep {
            let expected = intent &+ 1
            cancel { [weak self] result in
                guard let self, !self.stopped, self.session == nil, self.intent == expected else { return }
                guard case .success = result else { return }
                self.backend.perform(.sleep) { [weak self] in if case .failure(let error) = $0 { self?.report(error) } }
            }
        } else {
            // Hold the closed-lid override while asking loginwindow to shut down: releasing
            // it first could put a closed laptop to sleep before loginwindow receives the event.
            executing = true; changed()
            backend.perform(.shutDown) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result { self.report(error); self.cancel(); return }
                let id = target.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, self.executing, self.session?.id == id else { return }
                    self.cancel()
                    self.error = "Shutdown was requested. If another app cancelled it or needs attention, resolve that app and start a new timer."
                    self.changed()
                }
            }
        }
    }
    func sleepNow() {
        guard powerActionsAllowed else { return }
        let expected = intent &+ 1
        cancel { [weak self] result in
            guard let self, !self.stopped, self.session == nil, self.intent == expected, case .success = result else { return }
            self.backend.perform(.sleep) { [weak self] in if case .failure(let error) = $0 { self?.report(error) } }
        }
    }
    func shutdown(completion: @escaping (Result<Void, Error>) -> Void) {
        stopped = true; timer?.invalidate(); timer = nil; cancel(completion: completion)
    }
    func prepareHelperForUninstall() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backend.prepareForUninstall { continuation.resume(with: $0) }
        }
    }
    private func showWarning(_ session: PowerSession, seconds: Int) {
        guard showsWarnings else { return }
        if warning == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Awake & Sleep"; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
            let label = UI.label("", size: 17, weight: .semibold)
            let cancel = ActionButton("Cancel Session") { [weak self] in self?.cancel() }
            cancel.keyEquivalent = "\u{1b}"
            UI.pin(UI.vertical([label, UI.caption("Your selected timer is about to finish."), cancel], spacing: 12), in: panel.contentView!, inset: 18)
            panel.center(); panel.orderFrontRegardless(); warning = panel; warningLabel = label
            NSAccessibility.post(element: label, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(session.action == .sleep ? "Sleep" : "Shutdown") in 30 seconds. Cancel Session is available.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        warningLabel?.stringValue = "\(session.action == .sleep ? "Sleeping" : "Shutting down") in \(seconds) seconds"
    }
    private func dismissWarning() { warning?.orderOut(nil); warning = nil; warningLabel = nil }
    #if TESTING
    var warningForTesting: NSPanel? { warning }
    #endif
    deinit {
        timer?.invalidate(); observers.forEach { $0.0.removeObserver($0.1) }; warning?.orderOut(nil)
    }
}
