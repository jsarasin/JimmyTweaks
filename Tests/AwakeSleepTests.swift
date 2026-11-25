import AppKit

final class FixturePower: PowerBackend {
    var helperAvailable = true
    var helperStatus = "Fixture helper"
    var powerActionsAllowed = true
    var configurationError: Error?
    var helperNeedsApproval = false
    var canConfigureHelper: Bool { !helperAvailable && (powerActionsAllowed || helperNeedsApproval) }
    var events: [String] = []
    var pending: ((Result<Void, Error>) -> Void)?
    var delayBegin = false, delayEnd = false, failRenew = false, failEnd = false
    var setupFailure: String?
    func configureHelper() throws {
        events.append("configure")
        if let configurationError { throw configurationError }
        if let setupFailure { throw AwakeSleepError.message(setupFailure) }
    }
    func prepareForUninstall(completion: @escaping (Result<Void, Error>) -> Void) { events.append("uninstall"); completion(.success(())) }
    func begin(session: UUID, closedLid: Bool, display: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        events.append("begin:\(closedLid):\(display)")
        if delayBegin { pending = completion } else { completion(.success(())) }
    }
    func setDisplayAwake(_ enabled: Bool) throws { events.append("display:\(enabled)") }
    func renew(completion: @escaping (Result<Void, Error>) -> Void) {
        events.append("renew"); completion(failRenew ? .failure(AwakeSleepError.message("revoked")) : .success(()))
    }
    func end(completion: @escaping (Result<Void, Error>) -> Void) {
        events.append("end")
        if delayEnd { pending = completion } else { completion(failEnd ? .failure(AwakeSleepError.message("restore failed")) : .success(())) }
    }
    func perform(_ action: PowerAction, completion: @escaping (Result<Void, Error>) -> Void) {
        events.append("perform:\(action.rawValue)"); completion(.success(()))
    }
    func finish() { let callback = pending; pending = nil; callback?(.success(())) }
}

enum AwakeSleepTests {
    static func run(logger: FileLogger) {
        assert(PowerAction.keepAwake.presets == [30, 60, 120, 180, 300])
        assert(PowerAction.sleep.presets == [1, 5, 10, 30, 60, 180, 300, 600])
        assert(PowerAction.shutDown.presets == PowerAction.sleep.presets)
        assert(PowerAction.duration(hours: "2", minutes: "15") == 8100)
        for (h, m) in [("0", "0"), ("-1", "0"), ("1.5", "0"), ("0", "60"), ("bad", "2"), ("18446744073709551615", "0")] {
            assert(PowerAction.duration(hours: h, minutes: m) == nil)
        }
        let prefs = PreferenceStore(defaults: MemoryDefaults()), backend = FixturePower()
        var now: TimeInterval = 100
        let power = AwakeSleepController(preferences: prefs, logger: logger, backend: backend, now: { now }, automaticTimer: false, showsWarnings: false)
        assert(!prefs.bool(.keepDisplayAwake))
        power.start(.keepAwake, duration: 60)
        assert(backend.events.first == "begin:true:false")
        now = 130; power.tick(); assert(power.remaining == 30)
        now = 160; power.tick()
        assert(power.session == nil && backend.events.last == "end" && !backend.events.contains { $0.hasPrefix("perform:") })
        power.start(.sleep, duration: 60); now += 60; power.tick()
        assert(backend.events.suffix(2) == ["end", "perform:sleep"])
        power.start(.shutDown, duration: 60); power.cancel(); now += 100; power.tick()
        assert(!backend.events.contains("perform:shutDown"))
        power.start(.keepAwake, duration: nil); now += 100_000; power.tick(); assert(power.session?.deadline == nil)
        prefs.set(true, for: .keepDisplayAwake); assert(backend.events.last == "display:true")
        prefs.set(true, for: .suspended); assert(power.session == nil && backend.events.last == "end")
        power.start(.sleep, duration: 60); assert(power.session == nil)
        prefs.set(false, for: .suspended)
        power.start(.keepAwake, duration: nil); backend.failRenew = true; now += 5; power.tick()
        assert(power.session == nil && power.error == "revoked" && backend.events.last == "end")
        backend.failRenew = false; backend.helperAvailable = false
        power.start(.keepAwake, duration: nil); assert(backend.events.contains("begin:false:true"))
        NotificationCenter.default.post(name: NSWorkspace.willSleepNotification, object: nil) // Different center must not cancel.
        assert(power.session != nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        assert(power.session == nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        assert(power.session == nil)

        // Cancelling/replacing a pending helper acquisition must release the old one first.
        backend.delayBegin = true; backend.events = []
        power.start(.sleep, duration: 60); power.start(.keepAwake, duration: nil)
        backend.delayBegin = false; backend.finish()
        assert(backend.events.filter { $0 == "end" }.count == 1 && power.session?.action == .keepAwake)
        backend.delayEnd = true
        power.sleepNow(); power.start(.keepAwake, duration: nil)
        backend.delayEnd = false; backend.finish()
        assert(backend.events.filter { $0 == "perform:sleep" }.isEmpty, "A superseded immediate-sleep request cannot execute later")
        power.cancel()
        backend.failEnd = true
        power.start(.sleep, duration: 60); now += 60; power.tick()
        assert(power.error == "restore failed" && !backend.events.contains("perform:sleep"), "Do not sleep after failed cleanup")
        backend.failEnd = false
        power.start(.shutDown, duration: 60); now += 60; power.tick()
        assert(backend.events.last == "perform:shutDown", "Shutdown is requested before releasing a closed-lid override")
        now += 5; power.tick()
        assert(backend.events.last == "renew" && backend.events.filter { $0 == "perform:shutDown" }.count == 1, "Hold the lease while shutdown is pending without sending duplicate shutdown events")
        power.cancel()
        var stopped = false
        power.shutdown { _ in stopped = true }; assert(stopped)
        power.start(.sleep, duration: 60); assert(power.session == nil)

        let uiBackend = FixturePower()
        let uiPower = AwakeSleepController(preferences: prefs, logger: logger, backend: uiBackend, automaticTimer: false, showsWarnings: false)
        let menu = NSMenu(), binding = AwakeSleepMenu(controller: uiPower)
        binding.append(to: menu)
        let awakeMenu = menu.items.first { $0.title == "Keep Awake" }!.submenu!
        assert(awakeMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["30 minutes", "1 hour", "2 hours", "3 hours", "5 hours", "Indefinitely", "Custom…"])
        awakeMenu.performActionForItem(at: 1)
        assert(uiPower.session?.duration == 3600 && awakeMenu.item(at: 1)?.state == .on)
        menu.performActionForItem(at: menu.items.firstIndex { $0.title == "Cancel Session" }!)
        assert(uiPower.session == nil)
        helperSetupFailure(logger: logger)
        helperFailureBoundaries(logger: logger)
        let warningBackend = FixturePower()
        let warningPower = AwakeSleepController(preferences: prefs, logger: logger, backend: warningBackend, now: { now }, automaticTimer: false)
        warningPower.start(.sleep, duration: 60); now += 30; warningPower.tick()
        let warning = warningPower.warningForTesting!
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        assert(views(warning.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Sleeping in 30 seconds" })
        views(warning.contentView!).compactMap { $0 as? ActionButton }.first { $0.title == "Cancel Session" }!.performClick(nil)
        assert(warningPower.session == nil && warningPower.warningForTesting == nil && warningBackend.events.last == "end")
        now += 30; warningPower.tick(); assert(!warningBackend.events.contains("perform:sleep"))
        print("Awake & Sleep checks passed: durations, native menu routing, monotonic expiry, cancellation, replacement races, lifecycle, display, revocation, and action ordering; no real power actions performed.")
        lease()
    }
    private static func helperSetupFailure(logger: FileLogger) {
        let defaults = MemoryDefaults(), backend = FixturePower()
        backend.helperAvailable = false
        backend.setupFailure = "macOS could not register the closed-lid helper. " + String(repeating: "Operation not permitted. ", count: 30)
        let preferences = PreferenceStore(defaults: defaults)
        var alerts: [NSAlert] = []
        let power = AwakeSleepController(preferences: preferences, logger: logger, backend: backend,
                                        automaticTimer: false, observeSystem: false, showsWarnings: false,
                                        presentHelperFailure: { alerts.append($0) })
        let menu = NSMenu(), binding = AwakeSleepMenu(controller: power)
        menu.autoenablesItems = false; binding.append(to: menu)
        menu.performActionForItem(at: menu.items.firstIndex { $0.title == "Set Up Closed-Lid Helper…" }!)
        assert(alerts.count == 1 && alerts[0].messageText == "Closed-Lid Support Unavailable")
        assert(alerts[0].informativeText.contains(backend.setupFailure!) && alerts[0].informativeText.contains("permanently disabled"))
        assert(alerts[0].buttons.map(\.title) == ["OK"])
        assert(power.helperSetupFailed && !power.canConfigureHelper && !power.helperAvailable && power.error == nil)
        let unavailable = menu.items.first { $0.title == "Closed-Lid Helper Unavailable" }!
        assert(!unavailable.isEnabled && menu.items.allSatisfy { $0.title.count < 50 })
        power.configureHelper()
        assert(backend.events == ["configure"] && alerts.count == 1, "Failed setup must not retry or repeat its dialog")
        // A new controller and preference store represent an application relaunch.
        let relaunched = AwakeSleepController(preferences: PreferenceStore(defaults: defaults), logger: logger, backend: backend,
                                             automaticTimer: false, observeSystem: false, showsWarnings: false,
                                             presentHelperFailure: { _ in assertionFailure("Repeated setup warning after relaunch") })
        backend.helperAvailable = true
        relaunched.configureHelper()
        assert(relaunched.helperSetupFailed && !relaunched.helperAvailable && !relaunched.canConfigureHelper && backend.events == ["configure"])
        relaunched.start(.keepAwake, duration: nil)
        assert(relaunched.session != nil && backend.events.contains("begin:false:false"), "Idle keep-awake must remain usable after closed-lid setup fails")
        relaunched.cancel()
        power.start(.sleep, duration: 0)
        assert(power.error != nil)
        let failure = menu.items.first { $0.title == "Session Failed — See Settings" }!
        assert(!failure.isHidden && failure.toolTip == power.error && menu.items.allSatisfy { $0.title.count < 50 })
        print("Helper setup failure checks passed: one explanatory dialog, bounded menu titles, disabled setup, persistent failure across relaunch, and idle keep-awake fallback.")
    }
    private static func helperFailureBoundaries(logger: FileLogger) {
        let backend = FixturePower(), defaults = MemoryDefaults()
        backend.helperAvailable = false; backend.powerActionsAllowed = false
        let power = AwakeSleepController(preferences: PreferenceStore(defaults: defaults), logger: logger, backend: backend,
            automaticTimer: false, observeSystem: false, showsWarnings: false, presentHelperFailure: { _ in })
        for action in PowerAction.allCases { power.start(action, duration: 60) }
        power.sleepNow()
        assert(backend.events.isEmpty && power.session == nil, "Unresolved recovery must block all power actions")
        let menu = NSMenu(), binding = AwakeSleepMenu(controller: power)
        binding.append(to: menu)
        assert(menu.items.first { $0.title == "Stop & Sleep Now" }?.isEnabled == false)
        assert(menu.items.first { $0.title == "Keep Awake" }!.submenu!.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
        backend.powerActionsAllowed = true
        power.start(.keepAwake, duration: nil)
        assert(power.session != nil && backend.events.contains("begin:false:false"))
        power.cancel()
        for kind in [PowerHelperFailure.Kind.approval, .incompatible] {
            backend.configurationError = PowerHelperFailure(kind: kind, detail: "Fixture known cause")
            power.configureHelper()
            assert(!power.helperSetupFailed && !defaults.bool(forKey: WorkerLifecycle.setupFailedKey), "Known recoverable causes must not set permanent disablement")
        }
        var timer: DispatchWorkItem?, results: [Result<Void, Error>] = []
        let timeout = PowerHelperReplyGate(schedule: { _, item in timer = item }) { results.append($0) }
        timer!.perform()
        timeout.finish(.success(()))
        assert(results.count == 1)
        guard case .failure(let error) = results[0] else { fatalError("Timeout was lost") }
        assert((error as? PowerHelperFailure)?.untilReset == true && !error.localizedDescription.contains("will restore"))
        results = []
        let success = PowerHelperReplyGate(schedule: { _, item in timer = item }) { results.append($0) }
        success.finish(.success(()))
        timer!.perform()
        success.finish(.failure(AwakeSleepError.message("late transport error")))
        assert(results.count == 1)
        print("Helper failure boundaries passed: paused power actions, ordinary fallback, recoverable configuration errors, timeout/reply/error arbitration, and conditional restoration wording.")
    }
    private static func lease() {
        var disabled = false, stored: Bool?, clock: TimeInterval = 0
        var writes: [Bool] = [], failWrite = false, failJournal = false
        let lease = ClosedLidLease(read: { disabled }, write: { value in
            if failWrite { throw AwakeSleepError.message("write") }
            assert(stored != nil, "Journal must exist before every privileged power mutation")
            disabled = value; writes.append(value)
        }, journal: { original in
            if failJournal { throw AwakeSleepError.message("journal") }
            stored = original
        }, now: { clock })
        try! lease.acquire(owner: "a"); assert(disabled && stored == false)
        do { try lease.acquire(owner: "b"); assertionFailure("Other owner admitted") } catch {}
        try! lease.release(owner: "b"); assert(disabled)
        clock = 15; try! lease.renew(owner: "a"); clock = 21; try! lease.tick(); assert(disabled)
        clock = 35; try! lease.tick(); assert(!disabled && stored == nil && lease.owner == nil)
        disabled = true; try! lease.acquire(owner: "a"); try! lease.release(); assert(disabled, "Preserve an existing override")
        disabled = false; try! lease.acquire(owner: "a"); disabled = false; try! lease.renew(owner: "a"); assert(disabled, "Reapply after a power-source reset")
        failWrite = true
        do { try lease.release(); assertionFailure("Failed write ignored") } catch {}
        assert(stored == false && lease.original == false)
        failWrite = false; try! lease.tick(); assert(!disabled && stored == nil)
        failJournal = true
        let count = writes.count
        do { try lease.acquire(owner: "a"); assertionFailure("Missing journal ignored") } catch {}
        assert(writes.count == count && !disabled)
        failJournal = false; disabled = true; stored = false
        try! lease.recover(original: false); assert(!disabled && stored == nil)
        print("Closed-lid helper checks passed: owner isolation, renewable lease, power-source recovery, prior-setting preservation, durable-before-write ordering, failed restoration retry, and crash recovery.")
    }
}
