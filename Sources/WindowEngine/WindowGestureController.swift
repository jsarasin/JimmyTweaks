import AppKit
import ApplicationServices

struct RecoveryOwnership { var button: MouseButton?; var escape = false }
private func jimmyEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<WindowGestureController>.fromOpaque(userInfo).takeUnretainedValue().receive(proxy: proxy, type: type, event: event)
}

/// One session event tap. All mutable gesture state below belongs to its dedicated run loop.
final class WindowGestureController: @unchecked Sendable {
    var onReady: (() -> Void)?
    var onStopped: (() -> Void)?
    var onFailure: ((String, RecoveryOwnership) -> Void)?
    var onPermissionConcern: (() -> Void)?
    var onFeedback: ((GestureFeedback?) -> Void)?
    private let windows: WindowAccessing
    private let logger: FileLogger
    private let preferences: Locked<GesturePreferences>
    private let admission = Locked(true)
    private let loop = Locked<CFRunLoop?>(nil)
    private let stopping = Locked(false)
    private let discardPendingInput = Locked(false)
    private let currentButton = Locked<MouseButton?>(nil)
    private let gate = GenerationGate()
    private let initialOwnership: RecoveryOwnership
    private var thread: Thread?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var heartbeat: CFRunLoopTimer?
    private var machine = GestureMachine()
    private var heldDown: CGEvent?
    private var heldDrag: CGEvent?
    private var replayOnNextEvent = false
    private var target: WindowTarget?
    private var activeToken: UInt64 = 0
    private var pendingPoint: CGPoint?
    private var workerBusy = false
    private var finishing = false
    private var restoring = false
    private var restorationCounter: UInt64 = 0
    private var pumpScheduled = false
    private var lastWriteTime: TimeInterval = 0
    private var startedAt: TimeInterval?
    private var lastPointer = CGPoint.zero
    private var modifiers = Modifiers(command: false, extra: false)
    private var hoverBusy = false
    private var hoverGeneration: UInt64 = 0
    private var lastHoverTime: TimeInterval = 0
    private var exitFailure: String?
    private var exitOwnership = RecoveryOwnership()
    private static let replayMarker: Int64 = 0x4A544B535245504C

    init(preferences: GesturePreferences, windows: WindowAccessing, logger: FileLogger, ownership: RecoveryOwnership = RecoveryOwnership()) {
        self.preferences = Locked(preferences); self.windows = windows; self.logger = logger; self.initialOwnership = ownership
    }
    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Jimmy Tweaks Input"; thread.qualityOfService = .userInteractive
        self.thread = thread; thread.start()
    }
    func update(_ new: GesturePreferences) {
        let old = preferences.snapshot
        preferences.withValue { $0 = new }
        let button = currentButton.snapshot
        if !new.enabled || (button == .right && old.resizeEnabled && !new.resizeEnabled) || (button == .left && old.moveEnabled && !new.moveEnabled) { gate.close() }
        perform { [weak self] in
            guard let self = self else { return }
            let button = self.machine.session?.button ?? self.currentButton.snapshot
            if !new.enabled || (button == .left && !new.moveEnabled) || (button == .right && !new.resizeEnabled) {
                self.execute(self.machine.cancel(replayPending: true, reason: "gesture-disabled"), event: nil, proxy: nil)
                self.invalidatePipeline()
            }
            if self.machine.phase == .idle { self.requestHover(force: true) }
            else if let target = self.target { self.feedback(target.seed.frame, kind: target.seed.kind, active: self.machine.phase == .active) }
        }
    }
    func stop(discardPending: Bool, forceAfter: TimeInterval? = nil) {
        if discardPending { discardPendingInput.withValue { $0 = true } }
        admission.withValue { $0 = false }; stopping.withValue { $0 = true }; gate.close()
        perform { [weak self] in
            guard let self = self else { return }
            if self.discardPendingInput.snapshot { self.discardBufferedInput() }
            self.execute(self.machine.cancel(replayPending: !self.discardPendingInput.snapshot, reason: "engine-stop"), event: nil, proxy: nil)
            self.invalidatePipeline(); self.maybeStop()
        }
        if let delay = forceAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.perform { self?.tearDown() } }
        }
    }
    private func perform(_ body: @escaping () -> Void) {
        guard let runLoop = loop.snapshot else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, body); CFRunLoopWakeUp(runLoop)
    }
    private func run() {
        let runLoop = CFRunLoopGetCurrent()!
        loop.withValue { $0 = runLoop }
        let ownedButton = initialOwnership.button.flatMap { button in
            CGEventSource.buttonState(.combinedSessionState, button: button == .left ? .left : .right) ? button : nil
        }
        machine.adoptDrain(ownedButton, escape: initialOwnership.escape && CGEventSource.keyState(.combinedSessionState, key: 53))
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged,
                                   .rightMouseUp, .mouseMoved, .flagsChanged, .keyDown, .keyUp, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: jimmyEventCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = tap else {
            loop.withValue { $0 = nil }
            DispatchQueue.main.async { [self] in onFailure?("The system did not allow the input event tap to start.", initialOwnership) }
            return
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        heartbeat = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.05, 0.05, 0, 0) { [weak self] _ in
            guard let self = self else { return }
            if self.machine.phase == .draining || self.machine.escapeOwned {
                let released: Bool
                if let b = self.machine.session?.button { released = !CGEventSource.buttonState(.combinedSessionState, button: b == .left ? .left : .right) }
                else { released = true }
                self.machine.clearReleasedOwnership(mouseReleased: released, escapeReleased: !CGEventSource.keyState(.combinedSessionState, key: 53))
                self.maybeStop()
            }
        }
        CFRunLoopAddTimer(runLoop, heartbeat, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if stopping.snapshot { tearDown() }
        else {
            DispatchQueue.main.async { [self] in onReady?() }
            CFRunLoopRun()
        }
        gate.close()
        if let heartbeat = heartbeat { CFRunLoopTimerInvalidate(heartbeat) }
        if let source = source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap)
        self.tap = nil; self.source = nil; self.heartbeat = nil
        heldDown = nil; heldDrag = nil; replayOnNextEvent = false; target = nil; loop.withValue { $0 = nil }
        publishFeedback(nil)
        DispatchQueue.main.async { [self] in
            if let failure = exitFailure { onFailure?(failure, exitOwnership) } else { onStopped?() }
        }
    }

    fileprivate func receive(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let owned = machine.ownsSequence ? machine.session?.button : nil
            exitOwnership = RecoveryOwnership(button: owned, escape: machine.escapeOwned)
            exitFailure = type == .tapDisabledByTimeout ? "The system disabled the input tap after a timeout." : "The system disabled the input tap."
            gate.close(); publishFeedback(nil); tearDown(); return Unmanaged.passUnretained(event)
        }
        // A validation reply/deadline runs outside an event callback. Keep its two-event
        // buffer until a real callback supplies a proxy, so an already-queued physical
        // up cannot overtake a globally posted synthetic down.
        prepareBufferedInput(proxy: proxy)
        lastPointer = event.location
        let flags = event.flags
        let currentModifiers = Modifiers(command: flags.contains(.maskCommand), extra: !flags.intersection([.maskShift, .maskAlternate, .maskControl]).isEmpty)
        let input: GestureInput?
        switch type {
        case .leftMouseDown: input = .down(.left, event.location, currentModifiers)
        case .rightMouseDown: input = .down(.right, event.location, currentModifiers)
        case .leftMouseDragged: input = .drag(.left, event.location)
        case .rightMouseDragged: input = .drag(.right, event.location)
        case .leftMouseUp: input = .up(.left, event.location)
        case .rightMouseUp: input = .up(.right, event.location)
        case .flagsChanged: modifiers = currentModifiers; input = .flags(currentModifiers)
        case .keyDown:
            input = event.getIntegerValueField(.keyboardEventKeycode) == 53 ? .escapeDown : .interrupt
        case .keyUp:
            input = event.getIntegerValueField(.keyboardEventKeycode) == 53 ? .escapeUp : nil
        case .otherMouseDown, .scrollWheel: input = .interrupt
        default: input = nil
        }
        if let input = input {
            let decision = handle(input, event: event, proxy: proxy)
            if type == .flagsChanged, currentModifiers.qualifies { requestHover(force: true) }
            maybeStop()
            return decision.suppress ? nil : Unmanaged.passUnretained(event)
        }
        if type == .mouseMoved { modifiers = currentModifiers; requestHover(force: false) }
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ input: GestureInput, event: CGEvent?, proxy: CGEventTapProxy?) -> GestureDecision {
        let decision = machine.handle(input, preferences: preferences.snapshot,
                                      accepting: admission.snapshot && !finishing && !workerBusy)
        execute(decision, event: event, proxy: proxy)
        return decision
    }
    private func prepareBufferedInput(proxy: CGEventTapProxy?) {
        if discardPendingInput.snapshot, heldDown != nil { discardBufferedInput() }
        if replayOnNextEvent, let proxy = proxy { replayBufferedEvents(proxy: proxy) }
    }
    private func discardBufferedInput() {
        guard heldDown != nil else { return }
        machine.discardDeferredReplay()
        execute(machine.cancel(replayPending: false, reason: "context-change"), event: nil, proxy: nil)
        heldDown = nil; heldDrag = nil; replayOnNextEvent = false
    }
    private func execute(_ decision: GestureDecision, event: CGEvent?, proxy: CGEventTapProxy?) {
        for effect in decision.effects {
            switch effect {
            case .holdDown: heldDown = event?.copy(); heldDrag = nil
            case .holdDrag: heldDrag = event?.copy()
            case .replay:
                gate.close()
                // A physical callback has already checked the discard boundary.
                // Finish its balanced replay if a stop races with this callback.
                if let proxy = proxy { replayBufferedEvents(proxy: proxy) }
                else if discardPendingInput.snapshot { discardBufferedInput() }
                else { replayOnNextEvent = heldDown != nil }
                target = nil
            case .discard:
                heldDown = nil; heldDrag = nil; replayOnNextEvent = false
                if machine.phase != .active { gate.close(); target = nil }
            case .resolve(let id, let point, let button): resolve(id: id, point: point, button: button)
            case .began(let kind):
                startedAt = ProcessInfo.processInfo.systemUptime
                hoverGeneration &+= 1
                logger.log("gesture", "begin", "\(kind.name); target=\(target?.bundleID ?? "unknown.application")")
                if let target = target { feedback(target.seed.frame, kind: kind, active: true) }
            case .apply(let point): pendingPoint = point; pump()
            case .restore: restoreOriginal()
            case .end(let flush, let reason):
                let duration = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
                logger.log("gesture", reason == "escape" ? "cancel" : "end", "\(reason); duration=\(String(format: "%.2f", duration))s")
                startedAt = nil
                if reason == "escape", restoring { continue }
                if flush {
                    finishing = true
                    if pendingPoint == nil && !workerBusy { finishPipeline() } else { pump() }
                } else { invalidatePipeline() }
            case .hideFeedback: hoverGeneration &+= 1; publishFeedback(nil)
            }
        }
    }
    private func resolve(id: UInt64, point: CGPoint, button: MouseButton) {
        activeToken = id; currentButton.withValue { $0 = button }; gate.open(id)
        let config = machine.session?.preferences ?? preferences.snapshot
        let deadline = ProcessInfo.processInfo.systemUptime + 0.075
        windows.resolve(point: point, button: button, preferences: config, deadline: deadline,
                        stillValid: { [gate] in gate.valid(id) }) { [weak self] target in
            self?.perform { [weak self] in
                guard let self = self, self.machine.token == id, self.machine.phase == .resolving, self.gate.valid(id) else { return }
                self.target = target
                self.execute(self.machine.resolved(id: id, kind: target?.seed.kind), event: nil, proxy: nil)
                if self.machine.phase == .pending, let target = target { self.feedback(target.seed.frame, kind: target.seed.kind, active: false) }
            }
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.075) { [weak self] in
            self?.perform { [weak self] in
                guard let self = self else { return }
                self.execute(self.machine.timeout(id: id), event: nil, proxy: nil)
            }
        }
    }
    private func replayBufferedEvents(proxy: CGEventTapProxy) {
        for held in [heldDown, heldDrag].compactMap({ $0 }) {
            held.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            held.tapPostEvent(proxy)
        }
        heldDown = nil; heldDrag = nil; replayOnNextEvent = false
    }
    private func pump() {
        guard !workerBusy, let pointer = pendingPoint, let target = target, gate.valid(activeToken), !restoring else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = max(0, lastWriteTime + 1.0 / 60 - now)
        if wait > 0 {
            guard !pumpScheduled else { return }; pumpScheduled = true
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.perform { [weak self] in self?.pumpScheduled = false; self?.pump() }
            }
            return
        }
        pendingPoint = nil; workerBusy = true; lastWriteTime = now
        let token = activeToken
        windows.apply(target: target, pointer: pointer, generation: token, gate: gate, restoring: false) { [weak self] result in
            self?.perform { [weak self] in
                guard let self = self else { return }
                guard token == self.activeToken else { return }
                if !self.gate.valid(token) {
                    self.workerBusy = false
                    self.invalidatePipeline()
                    return
                }
                self.workerBusy = false
                switch result {
                case .success(let frame):
                    if !self.finishing { self.feedback(frame, kind: target.seed.kind, active: true) }
                case .failure(let error):
                    if case .ax(let code) = error, code == .apiDisabled {
                        DispatchQueue.main.async { [weak self] in self?.onPermissionConcern?() }
                    }
                    self.logger.rateLimited(target.bundleID + error.category, component: "accessibility", event: "target.failure",
                                            message: "target=\(target.bundleID); \(error.category)")
                    self.execute(self.machine.cancel(replayPending: false, reason: error.category), event: nil, proxy: nil)
                    self.invalidatePipeline()
                }
                if self.finishing && self.pendingPoint == nil { self.finishPipeline() }
                else { self.pump() }
            }
        }
    }
    private func restoreOriginal() {
        guard let target = target else { return }
        gate.close(); pendingPoint = nil
        restorationCounter &+= 1; activeToken = UInt64.max - restorationCounter
        let token = activeToken
        gate.open(token); restoring = true; finishing = true; workerBusy = true
        windows.apply(target: target, pointer: target.seed.pointer, generation: token, gate: gate, restoring: true) { [weak self] result in
            self?.perform { [weak self] in
                guard let self = self, self.activeToken == token else { return }
                self.workerBusy = false
                if case .failure(let error) = result {
                    self.logger.log("gesture", "restore.failure", "target=\(target.bundleID); \(error.category)", severity: "WARN")
                }
                self.finishPipeline()
            }
        }
    }
    private func invalidatePipeline() {
        gate.close(); pendingPoint = nil; target = nil; finishing = false; restoring = false
        hoverGeneration &+= 1; publishFeedback(nil)
    }
    private func finishPipeline() { gate.close(); target = nil; pendingPoint = nil; finishing = false; restoring = false; publishFeedback(nil) }
    private func requestHover(force: Bool) {
        guard machine.phase == .idle, !finishing, admission.snapshot, modifiers.qualifies else {
            if machine.phase == .idle { publishFeedback(nil) }; return
        }
        let config = preferences.snapshot
        guard config.changeCursor || config.cornerHints, !hoverBusy else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastHoverTime >= 0.05 else { return }
        lastHoverTime = now; hoverBusy = true; hoverGeneration &+= 1
        let generation = hoverGeneration, pointer = lastPointer
        windows.resolve(point: pointer, button: nil, preferences: config, deadline: now + 0.075,
                        stillValid: { [weak self] in self?.admission.snapshot == true }) { [weak self] hit in
            self?.perform { [weak self] in
                guard let self = self else { return }; self.hoverBusy = false
                guard generation == self.hoverGeneration, self.machine.phase == .idle,
                      self.modifiers.qualifies, self.admission.snapshot else { return }
                if WindowGeometry.distance(pointer, self.lastPointer) > 8 { self.requestHover(force: true); return }
                if let hit = hit { self.feedback(hit.seed.frame, kind: hit.seed.kind, active: false) }
                else { self.publishFeedback(nil) }
            }
        }
    }
    private func feedback(_ frame: CGRect, kind: GestureKind, active: Bool) {
        publishFeedback(GestureFeedback(frame: frame, kind: kind, active: active, preferences: preferences.snapshot))
    }
    private func publishFeedback(_ feedback: GestureFeedback?) { DispatchQueue.main.async { [weak self] in self?.onFeedback?(feedback) } }
    private func maybeStop() { if stopping.snapshot && !machine.ownsSequence && !replayOnNextEvent { tearDown() } }
    private func tearDown() { gate.close(); if let runLoop = loop.snapshot { CFRunLoopStop(runLoop) } }
}

#if TESTING
extension WindowGestureController {
    func attachToCurrentRunLoopForTesting() { loop.withValue { $0 = CFRunLoopGetCurrent() } }
    @discardableResult func handleForTesting(_ input: GestureInput, event: CGEvent? = nil) -> GestureDecision {
        prepareBufferedInput(proxy: nil)
        return handle(input, event: event, proxy: nil)
    }
    var hasDeferredReplayForTesting: Bool { replayOnNextEvent && heldDown != nil }
    var ownsSequenceForTesting: Bool { machine.ownsSequence }
}
#endif
