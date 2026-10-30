import AppKit

enum RuntimeState: String {
    case disabled = "Disabled", suspended = "Suspended", paused = "Paused — Session Inactive"
    case permission = "Permission Required", starting = "Starting", running = "Running", failed = "Failed"
}

final class RuntimeCoordinator: NSObject {
    let preferences: PreferenceStore
    let permissions: PermissionCoordinator
    let logger: FileLogger
    private let windows = AccessibilityWindows()
    private let feedback = FeedbackController()
    private var engine: WindowGestureController?
    private var engineReady = false
    private var engineStopping = false
    private var retryWork: DispatchWorkItem?
    private var stableWork: DispatchWorkItem?
    private var workGeneration: UInt64 = 0
    private var recovery = RecoveryOwnership()
    private var budget = RetryBudget()
    private var failed = false
    private var failureDetail = ""
    private var wasEnabled: Bool
    private var sessionActive = true
    private var shutdownCompletion: (() -> Void)?
    private var shuttingDown = false
    private(set) var state: RuntimeState = .disabled
    private(set) var detail = ""
    private(set) var lastFailure: Date?
    private var observers: [NSObjectProtocol] = []

    init(preferences: PreferenceStore, permissions: PermissionCoordinator, logger: FileLogger) {
        self.preferences = preferences; self.permissions = permissions; self.logger = logger
        self.wasEnabled = preferences.bool(.enabled)
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: .preferencesChanged, object: preferences, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let enabled = self.preferences.bool(.enabled)
            if !self.wasEnabled && enabled { self.failed = false; self.budget.reset() }
            self.wasEnabled = enabled
            self.logger.log("preferences", "changed", "Application preferences changed."); self.reconcile()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .permissionsChanged, object: permissions, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.logger.log("permissions", "changed", self.permissions.ready ? "Required capabilities available." : "Required capabilities unavailable.")
            if self.permissions.ready {
                // A fresh grant deserves a fresh startup attempt, even after earlier failures.
                self.failed = false; self.budget.reset(); self.lastFailure = nil; self.cancelRetry()
            }
            self.reconcile()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sessionActive = false; self?.reconcile() })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = true; self?.permissions.refresh(); self?.reconcile()
            })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.contextChanged() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.contextChanged() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.permissions.refresh() })
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        retryWork?.cancel(); stableWork?.cancel()
    }
    var gestureSummary: String {
        let p = preferences.gesture
        if !p.enabled { return "Window Resizer is switched off." }
        if !p.resizeEnabled && !p.moveEnabled { return "Both gestures are switched off." }
        let enabled = [p.resizeEnabled ? "resizing" : nil, p.moveEnabled ? "moving" : nil].compactMap { $0 }
        return enabled.joined(separator: " and ").capitalized + " enabled."
    }
    func reconcile() {
        guard !shuttingDown else { return }
        let p = preferences.gesture
        let blocker: (RuntimeState, String)?
        if preferences.bool(.suspended) { blocker = (.suspended, "Enabled features are paused. Your individual settings are preserved.") }
        else if !p.anyGesture { blocker = (.disabled, !p.enabled ? "Window Resizer is switched off." : "Both gestures are switched off.") }
        else if !sessionActive { blocker = (.paused, "Features resume after this user session becomes active.") }
        else if !permissions.ready { blocker = (.permission, permissions.summary) }
        else if failed { blocker = (.failed, failureDetail) }
        else { blocker = nil }
        permissions.setBackgroundEligible(p.anyGesture && !preferences.bool(.suspended) && sessionActive)
        if let blocker = blocker {
            cancelRetry(); stopEngine(discard: !sessionActive); setState(blocker.0, blocker.1); return
        }
        if let engine = engine {
            engine.update(p)
            if engineStopping { setState(.starting, "Finishing input cleanup before restarting.") }
            else { setState(engineReady ? .running : .starting, gestureSummary) }
            return
        }
        if retryWork != nil { setState(.starting, "Recovering after an input-engine fault."); return }
        startEngine(p)
    }
    func retry() {
        failed = false; budget.reset(); lastFailure = nil; cancelRetry()
        permissions.refresh(); reconcile()
    }
    private func startEngine(_ p: GesturePreferences) {
        let engine = WindowGestureController(preferences: p, windows: windows, logger: logger, ownership: recovery)
        self.engine = engine; engineReady = false; engineStopping = false
        engine.onReady = { [weak self, weak engine] in
            guard let self = self, let engine = engine, self.engine === engine else { return }
            self.engineReady = true; self.recovery = RecoveryOwnership(); self.setState(.running, self.gestureSummary)
            let stable = DispatchWorkItem { [weak self, weak engine] in
                guard let self = self, let engine = engine, self.engine === engine, self.engineReady else { return }
                self.budget.reset()
            }
            self.stableWork?.cancel(); self.stableWork = stable
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: stable)
        }
        engine.onFeedback = { [weak self, weak engine] state in
            guard let self = self, let engine = engine, self.engine === engine else { return }
            if !self.preferences.bool(.suspended) && self.sessionActive && !self.engineStopping { self.feedback.show(state) }
            else { self.feedback.clear() }
        }
        engine.onPermissionConcern = { [weak self] in self?.permissions.refresh() }
        engine.onStopped = { [weak self, weak engine] in
            guard let self = self, let engine = engine, self.engine === engine else { return }
            self.engine = nil; self.engineReady = false; self.engineStopping = false; self.feedback.clear()
            if self.shuttingDown { self.completeShutdown() } else { self.reconcile() }
        }
        engine.onFailure = { [weak self, weak engine] message, ownership in
            guard let self = self, let engine = engine, self.engine === engine else { return }
            self.engine = nil; self.engineReady = false; self.engineStopping = false; self.stableWork?.cancel(); self.feedback.clear()
            self.recovery = ownership
            if self.shuttingDown { self.completeShutdown(); return }
            self.permissions.refresh(notify: false)
            guard self.permissions.ready, self.sessionActive, self.preferences.gesture.anyGesture, !self.preferences.bool(.suspended) else { self.reconcile(); return }
            self.lastFailure = Date(); self.logger.log("runtime", "engine.failure", message, severity: "WARN")
            guard let delay = self.budget.nextDelay(now: ProcessInfo.processInfo.systemUptime) else {
                self.failed = true; self.failureDetail = message + " Automatic retries are exhausted. Choose Retry or review the log."
                self.setState(.failed, self.failureDetail); return
            }
            self.workGeneration &+= 1; let generation = self.workGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.workGeneration == generation else { return }
                self.retryWork = nil; self.reconcile()
            }
            self.retryWork = work; self.setState(.starting, "Input engine retry in \(Int(delay)) second(s).")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        setState(.starting, "Starting window gestures."); engine.start()
    }
    private func stopEngine(discard: Bool) {
        feedback.clear(); stableWork?.cancel()
        guard let engine = engine else { return }
        if engineStopping {
            if discard { engine.stop(discardPending: true) }
            return
        }
        engineStopping = true; engineReady = false
        engine.stop(discardPending: discard)
    }
    private func contextChanged() { stopEngine(discard: true); reconcile() }
    func endGestureForReset() { stopEngine(discard: false) }
    private func cancelRetry() { workGeneration &+= 1; retryWork?.cancel(); retryWork = nil }
    private func setState(_ state: RuntimeState, _ detail: String) {
        guard state != self.state || detail != self.detail else { return }
        self.state = state; self.detail = detail
        logger.log("runtime", "state", state.rawValue + ": " + detail)
        NotificationCenter.default.post(name: .runtimeChanged, object: self)
    }
    func shutdown(completion: @escaping () -> Void) {
        shuttingDown = true; shutdownCompletion = completion; cancelRetry(); stableWork?.cancel(); feedback.clear()
        if let engine = engine { engineStopping = true; engine.stop(discardPending: !sessionActive, forceAfter: 0.5) }
        else { completeShutdown() }
    }
    private func completeShutdown() { let completion = shutdownCompletion; shutdownCompletion = nil; completion?() }
}
