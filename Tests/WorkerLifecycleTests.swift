import AppKit
import ServiceManagement

private final class FixtureWorker: ManagedWorkerService {
    var status: SMAppService.Status
    var registerFailure = false, unregisterFailure = false
    let name: String
    let event: (String) -> Void
    init(_ name: String, status: SMAppService.Status, event: @escaping (String) -> Void) { self.name = name; self.status = status; self.event = event }
    func register() throws {
        event(name + ".register")
        if registerFailure { throw AwakeSleepError.message("register failed") }
        status = .enabled
    }
    func unregister() async throws {
        event(name + ".unregister")
        if unregisterFailure { throw AwakeSleepError.message("unregister failed") }
        status = .notRegistered
    }
}

enum WorkerLifecycleTests {
    @MainActor static func run(root: URL) async throws {
        let defaults = MemoryDefaults()
        defaults.set("old", forKey: WorkerLifecycle.installationKey)
        defaults.set("preserved", forKey: "customShortcuts.definitions")
        var events: [String] = []
        let power = FixtureWorker("power", status: .enabled) { events.append($0) }
        let login = FixtureWorker("login", status: .enabled) { events.append($0) }
        var recoveryExists = false
        let workers = WorkerLifecycle(defaults: defaults, power: power, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { recoveryExists }, readSleepDisabled: { true }, validateInstallation: {})
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "restore", "power.unregister", "power.register", "restore"])
        assert(workers.error == nil && defaults.string(forKey: WorkerLifecycle.installationKey) == "new")
        assert(defaults.string(forKey: "customShortcuts.definitions") == "preserved")
        events = []; await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"], "An unchanged worker is not unnecessarily reinstalled")
        defaults.set("old", forKey: WorkerLifecycle.installationKey); events = []
        await workers.prepareForLaunch { throw AwakeSleepError.message("cannot restore") }
        assert(events == ["retire"] && workers.error != nil && defaults.string(forKey: WorkerLifecycle.installationKey) == "old")
        defaults.removeObject(forKey: WorkerLifecycle.failureKey); defaults.removeObject(forKey: WorkerLifecycle.disabledKey)
        power.status = .requiresApproval; recoveryExists = true; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"] && workers.error != nil, "Never kill a worker with an unresolved restoration journal")
        recoveryExists = false; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"] && workers.blockingError == nil && power.status == .requiresApproval)
        assert(defaults.string(forKey: WorkerLifecycle.installationKey) == "old", "Defer replacement until the user approves the existing helper")
        power.status = .enabled; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "restore", "power.unregister", "power.register", "restore"])
        defaults.set("old", forKey: WorkerLifecycle.installationKey); power.registerFailure = true; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(workers.error != nil && power.status == .notRegistered && defaults.bool(forKey: WorkerLifecycle.reinstallKey))
        defaults.removeObject(forKey: WorkerLifecycle.failureKey); defaults.removeObject(forKey: WorkerLifecycle.disabledKey)
        power.registerFailure = false; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register", "restore"] && workers.error == nil && !defaults.bool(forKey: WorkerLifecycle.reinstallKey), "Retry an update that failed after removing the old worker")
        power.unregisterFailure = true; events = []
        do { try await workers.uninstall { events.append("restore") }; assertionFailure("Cleanup failure hidden") } catch {}
        assert(events == ["restore", "power.unregister", "login.unregister"], "Attempt independent login cleanup even when power-worker removal fails")
        assert(defaults.string(forKey: WorkerLifecycle.installationKey) != nil)
        power.unregisterFailure = false; login.status = .enabled; events = []
        try await workers.uninstall { events.append("restore") }
        assert(events == ["restore", "power.unregister", "login.unregister"])
        assert(defaults.string(forKey: WorkerLifecycle.installationKey) == nil)
        defaults.set("old", forKey: WorkerLifecycle.installationKey); events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"] && power.status == .notRegistered, "Updating must not silently install a previously disabled helper")

        // A fresh ad-hoc launch can report notFound. Older builds incorrectly
        // tried unregister/register and left a retry flag after EPERM.
        for status in [SMAppService.Status.notFound, .notRegistered, .requiresApproval] {
            let fresh = MemoryDefaults()
            fresh.set(true, forKey: WorkerLifecycle.legacyReinstallKey)
            fresh.set("preserved", forKey: "customShortcuts.definitions")
            let missing = FixtureWorker("power", status: status) { events.append($0) }
            missing.registerFailure = true; missing.unregisterFailure = true
            let firstLaunch = WorkerLifecycle(defaults: fresh, power: missing, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { false }, readSleepDisabled: { true }, validateInstallation: {})
            events = []; await firstLaunch.prepareForLaunch { events.append("restore") }
            assert(events == ["retire"] && firstLaunch.blockingError == nil, "An optional, unconfigured helper must not prevent launching")
            assert(!fresh.bool(forKey: WorkerLifecycle.reinstallKey) && fresh.object(forKey: WorkerLifecycle.legacyReinstallKey) == nil, "Discard the failed first-launch retry flag")
            assert(fresh.string(forKey: "customShortcuts.definitions") == "preserved")
            events = []; await firstLaunch.prepareForLaunch { events.append("restore") }
            assert(events == ["retire"] && firstLaunch.blockingError == nil)
        }
        let interrupted = MemoryDefaults()
        let replacement = FixtureWorker("power", status: .enabled) { events.append($0) }
        replacement.registerFailure = true
        let initialUpdate = WorkerLifecycle(defaults: interrupted, power: replacement, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { false }, readSleepDisabled: { true }, validateInstallation: {})
        events = []; await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(initialUpdate.error != nil && interrupted.bool(forKey: WorkerLifecycle.reinstallKey))
        interrupted.removeObject(forKey: WorkerLifecycle.failureKey); interrupted.removeObject(forKey: WorkerLifecycle.disabledKey)
        replacement.registerFailure = false; events = []
        await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register", "restore"] && initialUpdate.error == nil, "A genuine interrupted update retries even without an older fingerprint")
        interrupted.set(true, forKey: WorkerLifecycle.reinstallKey); replacement.status = .notRegistered; events = []
        await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register", "restore"], "Pending recovery takes precedence over an unchanged fingerprint")
        interrupted.set("old", forKey: WorkerLifecycle.installationKey)
        interrupted.set(true, forKey: WorkerLifecycle.legacyReinstallKey)
        replacement.status = .notRegistered; events = []
        await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register", "restore"] && interrupted.object(forKey: WorkerLifecycle.legacyReinstallKey) == nil, "Migrate an interrupted legacy update with an installation record")
        for status in [SMAppService.Status.notFound, .requiresApproval] {
            interrupted.set("old", forKey: WorkerLifecycle.installationKey)
            interrupted.set(true, forKey: WorkerLifecycle.reinstallKey)
            replacement.status = status; events = []
            await initialUpdate.prepareForLaunch { events.append("restore") }
            assert(events == ["retire"] && initialUpdate.blockingError == nil && interrupted.bool(forKey: WorkerLifecycle.reinstallKey), "Defer a pending update while its service cannot be managed")
        }
        let unresolved = WorkerLifecycle(defaults: interrupted, power: replacement, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { true }, readSleepDisabled: { true }, validateInstallation: {})
        replacement.status = .notFound; events = []
        await unresolved.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"] && unresolved.error != nil, "A missing helper with a restoration journal still requires recovery")

        try await recoveryPolicies(root: root)
        let id = "local.jimmytweaks.cleanup-fixture", home = root.appendingPathComponent("fake-home")
        let paths = try FreshInstallCleanup.directories(home: home, bundleIdentifier: id)
        for path in paths {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("owned".utf8).write(to: path.appendingPathComponent("owned.txt"))
        }
        let unrelated = home.appendingPathComponent("Library/Caches/unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let logger = FileLogger(directory: paths[0], maintenance: false)
        logger.log("test", "cleanup", "owned")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in logger.shutdown { continuation.resume() } }
        try FreshInstallCleanup.removeUserData(bundleIdentifier: id, defaults: defaults, home: home)
        assert(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        assert(FileManager.default.fileExists(atPath: unrelated.path))
        assert(defaults.string(forKey: "customShortcuts.definitions") == nil)
        logger.log("test", "late", "must not recreate the removed directory")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            logger.flush { result in
                guard case .failure = result else { assertionFailure("Stopped logger reopened deleted files"); continuation.resume(); return }
                continuation.resume()
            }
        }
        assert(!FileManager.default.fileExists(atPath: paths[0].path))
        for invalid in ["", "../other", "global", "local/app"] {
            do { _ = try FreshInstallCleanup.directories(home: home, bundleIdentifier: invalid); assertionFailure("Unsafe cleanup identity admitted") } catch {}
        }
        print("Worker lifecycle checks passed: restore-before-update, unchanged/disabled/missing workers, stale retry migration, interrupted update recovery, revoked approval, independent uninstall attempts, app-only data removal, and no log resurrection.")
    }
    @MainActor private static func recoveryPolicies(root: URL) async throws {
        let defaults = MemoryDefaults()
        defaults.set("old", forKey: WorkerLifecycle.installationKey)
        defaults.set("keep", forKey: "customShortcuts.definitions")
        var events: [String] = [], recovery = false, disabled = false, probeFails = false
        let power = FixtureWorker("power", status: .enabled) { events.append($0) }
        let login = FixtureWorker("login", status: .enabled) { events.append($0) }
        func worker(_ identity: String = "new") -> WorkerLifecycle {
            WorkerLifecycle(defaults: defaults, power: power, login: login, identity: { identity },
                retirePrevious: { events.append("retire") }, hasRecoveryJournal: { recovery },
                readSleepDisabled: {
                    events.append("probe")
                    if probeFails { throw AwakeSleepError.message("unreadable") }
                    return disabled
                }, validateInstallation: {})
        }
        let timeout = PowerHelperFailure(kind: .unavailable, detail: "Fixture timeout")
        let failed = worker()
        await failed.prepareForLaunch { events.append("restore"); throw timeout }
        assert(events == ["retire", "restore", "probe", "power.unregister"])
        assert(failed.disabledUntilReset && failed.blockingError == nil && !failed.restorationPending)
        assert(defaults.string(forKey: WorkerLifecycle.installationKey) == "old")
        // Relaunch and a different build must not retry or implicitly clear the latch.
        events = []
        let relaunched = worker("another-build")
        await relaunched.prepareForLaunch { assertionFailure("Retried a disabled worker") }
        assert(events == ["retire", "probe"] && relaunched.disabledUntilReset)
        assert(defaults.string(forKey: "customShortcuts.definitions") == "keep")
        _ = relaunched.configurationFailed(PowerHelperFailure(kind: .incompatible, detail: "Fixture signature failure during cleanup"))
        assert(relaunched.disabledUntilReset, "A later known error must not clear an earlier unknown-failure latch")
        login.unregisterFailure = true
        do { try await relaunched.uninstall {}; assertionFailure("Reset failure ignored") } catch {}
        assert(relaunched.disabledUntilReset && defaults.string(forKey: WorkerLifecycle.installationKey) == "old")
        login.unregisterFailure = false
        try await relaunched.uninstall {}
        assert(!relaunched.disabledUntilReset && defaults.data(forKey: WorkerLifecycle.failureKey) == nil)

        let rejected = worker()
        await rejected.handleFailure(PowerHelperFailure(kind: .session, detail: "This lease expired; start a new session."), operation: "renew")
        assert(!rejected.disabledUntilReset && rejected.error == nil && defaults.data(forKey: WorkerLifecycle.failureKey) == nil,
            "An explicit session rejection is not an unexplained communication failure")

        // A journal, an active override, or an unsuccessful probe all forbid retirement.
        for scenario in 0..<3 {
            defaults.removeObject(forKey: WorkerLifecycle.failureKey); defaults.removeObject(forKey: WorkerLifecycle.disabledKey)
            power.status = .enabled; events = []
            recovery = scenario == 0; disabled = scenario == 1; probeFails = scenario == 2
            let unsafe = worker()
            await unsafe.prepareForLaunch { throw timeout }
            assert(unsafe.restorationPending && unsafe.blockingError == nil)
            assert(!events.contains("power.unregister") && !events.contains("power.register"))
            do { try await unsafe.uninstall { throw timeout }; assertionFailure("Unsafe reset accepted") } catch {}
            assert(unsafe.disabledUntilReset && power.status == .enabled)
            recovery = false; disabled = false; probeFails = false
            await unsafe.refreshRestorationState()
            assert(!unsafe.restorationPending && unsafe.disabledUntilReset, "Read-only recovery may re-enable ordinary power actions, never helper retries")
            try await unsafe.uninstall { throw timeout }
            assert(!unsafe.disabledUntilReset && power.status == .notRegistered)
        }
        // A marker appearing during the probe is also unsafe.
        power.status = .enabled
        let racing = WorkerLifecycle(defaults: defaults, power: power, login: login, identity: { "new" }, retirePrevious: {},
            hasRecoveryJournal: { recovery }, readSleepDisabled: { recovery = true; return false }, validateInstallation: {})
        await racing.prepareForLaunch { throw timeout }
        assert(racing.restorationPending && power.status == .enabled)
        defaults.removeObject(forKey: WorkerLifecycle.failureKey); defaults.removeObject(forKey: WorkerLifecycle.disabledKey); recovery = false

        let incompatible = WorkerLifecycle(defaults: defaults, power: power, login: login, identity: { "new" }, retirePrevious: {},
            hasRecoveryJournal: { false }, readSleepDisabled: { true }, validateInstallation: {
                throw PowerHelperFailure(kind: .incompatible, detail: "Fixture invalid signature")
            })
        events = []
        await incompatible.prepareForLaunch { events.append("restore") }
        assert(events == ["restore"] && !incompatible.disabledUntilReset && incompatible.blockingError == nil && !incompatible.restorationPending)
        assert(power.status == .enabled, "Do not replace a restored old worker with an incompatible installation")

        defaults.removeObject(forKey: WorkerLifecycle.failureKey); defaults.removeObject(forKey: WorkerLifecycle.disabledKey)
        power.status = .requiresApproval; recovery = true
        let approval = worker()
        await approval.prepareForLaunch { assertionFailure("Contacted an unapproved helper") }
        assert(approval.needsApproval && approval.canConfigure && approval.restorationPending && !approval.disabledUntilReset)
        defaults.set(true, forKey: WorkerLifecycle.setupFailedKey)
        events = []
        let legacy = worker()
        await legacy.prepareForLaunch { assertionFailure("Ignored the existing setup disablement") }
        assert(legacy.disabledUntilReset && legacy.blockingError == nil && !events.contains("power.register"))
        defaults.removeObject(forKey: WorkerLifecycle.setupFailedKey)
        let blocked = WorkerLifecycle(defaults: defaults, power: power, login: login, identity: { "new" },
            retirePrevious: { throw AwakeSleepError.message("Older app is still running") }, hasRecoveryJournal: { false })
        await blocked.prepareForLaunch { assertionFailure("Continued after a duplicate-app failure") }
        assert(blocked.blockingError != nil)

        let clear = try PowerHelperSafety.parseSleepDisabled("System-wide power settings:\n SleepDisabled 0\n")
        assert(!clear)
        let set = try PowerHelperSafety.parseSleepDisabled("SleepDisabled\t1")
        assert(set)
        do { _ = try PowerHelperSafety.parseSleepDisabled("SleepDisabled unknown"); assertionFailure("Guessed missing sleep state") } catch {}
        assert(!PowerHelperSafety.recoveryMayExist(at: root.appendingPathComponent("missing-recovery").path))
        let protected = root.appendingPathComponent("protected-recovery")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protected.path)
        assert(PowerHelperSafety.recoveryMayExist(at: protected.appendingPathComponent("unreadable-child").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path)
        try FileManager.default.removeItem(at: protected)
        let app = root.appendingPathComponent("Fixture.app")
        let executable = app.appendingPathComponent("Contents/Library/HelperTools/AwakeSleepHelper")
        let enclosing = try PowerHelperSafety.enclosingApp(executable: executable)
        assert(enclosing.path == app.path)
        do { _ = try PowerHelperSafety.enclosingApp(executable: app.appendingPathComponent("wrong")); assertionFailure("Invalid helper layout accepted") } catch {}
        let running = try PowerHelperSafety.executableURL()
        assert(running.lastPathComponent == "AwakeSleepFeatureCheck")
        assert(PowerHelperSafety.terminalExitCode(recoveryMayExist: false) == 0)
        assert(PowerHelperSafety.terminalExitCode(recoveryMayExist: true) == 1)
        print("Helper recovery policies passed: safe retirement, persistent timeout disablement, cause-specific approval/signature handling, conservative probes, failed/successful reset, executable resolution, and restart policy.")
    }

}
