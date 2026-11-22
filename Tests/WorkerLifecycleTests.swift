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
        let workers = WorkerLifecycle(defaults: defaults, power: power, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { recoveryExists })
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "restore", "power.unregister", "power.register"])
        assert(workers.error == nil && defaults.string(forKey: WorkerLifecycle.installationKey) == "new")
        assert(defaults.string(forKey: "customShortcuts.definitions") == "preserved")
        events = []; await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"], "An unchanged worker is not unnecessarily reinstalled")
        defaults.set("old", forKey: WorkerLifecycle.installationKey); events = []
        await workers.prepareForLaunch { throw AwakeSleepError.message("cannot restore") }
        assert(events == ["retire"] && workers.error != nil && defaults.string(forKey: WorkerLifecycle.installationKey) == "old")
        power.status = .requiresApproval; recoveryExists = true; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"] && workers.error != nil, "Never kill a worker with an unresolved restoration journal")
        recoveryExists = false; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"] && workers.error == nil && power.status == .requiresApproval)
        assert(defaults.string(forKey: WorkerLifecycle.installationKey) == "old", "Defer replacement until the user approves the existing helper")
        power.status = .enabled; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "restore", "power.unregister", "power.register"])
        defaults.set("old", forKey: WorkerLifecycle.installationKey); power.registerFailure = true; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(workers.error != nil && power.status == .notRegistered && defaults.bool(forKey: WorkerLifecycle.reinstallKey))
        power.registerFailure = false; events = []
        await workers.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register"] && workers.error == nil && !defaults.bool(forKey: WorkerLifecycle.reinstallKey), "Retry an update that failed after removing the old worker")
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
            let firstLaunch = WorkerLifecycle(defaults: fresh, power: missing, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { false })
            events = []; await firstLaunch.prepareForLaunch { events.append("restore") }
            assert(events == ["retire"] && firstLaunch.error == nil, "An optional, unconfigured helper must not prevent launching")
            assert(!fresh.bool(forKey: WorkerLifecycle.reinstallKey) && fresh.object(forKey: WorkerLifecycle.legacyReinstallKey) == nil, "Discard the failed first-launch retry flag")
            assert(fresh.string(forKey: "customShortcuts.definitions") == "preserved")
            events = []; await firstLaunch.prepareForLaunch { events.append("restore") }
            assert(events == ["retire"] && firstLaunch.error == nil)
        }
        let interrupted = MemoryDefaults()
        let replacement = FixtureWorker("power", status: .enabled) { events.append($0) }
        replacement.registerFailure = true
        let initialUpdate = WorkerLifecycle(defaults: interrupted, power: replacement, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { false })
        events = []; await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(initialUpdate.error != nil && interrupted.bool(forKey: WorkerLifecycle.reinstallKey))
        replacement.registerFailure = false; events = []
        await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register"] && initialUpdate.error == nil, "A genuine interrupted update retries even without an older fingerprint")
        interrupted.set(true, forKey: WorkerLifecycle.reinstallKey); replacement.status = .notRegistered; events = []
        await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register"], "Pending recovery takes precedence over an unchanged fingerprint")
        interrupted.set("old", forKey: WorkerLifecycle.installationKey)
        interrupted.set(true, forKey: WorkerLifecycle.legacyReinstallKey)
        replacement.status = .notRegistered; events = []
        await initialUpdate.prepareForLaunch { events.append("restore") }
        assert(events == ["retire", "power.register"] && interrupted.object(forKey: WorkerLifecycle.legacyReinstallKey) == nil, "Migrate an interrupted legacy update with an installation record")
        for status in [SMAppService.Status.notFound, .requiresApproval] {
            interrupted.set("old", forKey: WorkerLifecycle.installationKey)
            interrupted.set(true, forKey: WorkerLifecycle.reinstallKey)
            replacement.status = status; events = []
            await initialUpdate.prepareForLaunch { events.append("restore") }
            assert(events == ["retire"] && initialUpdate.error == nil && interrupted.bool(forKey: WorkerLifecycle.reinstallKey), "Defer a pending update while its service cannot be managed")
        }
        let unresolved = WorkerLifecycle(defaults: interrupted, power: replacement, login: login, identity: { "new" }, retirePrevious: { events.append("retire") }, hasRecoveryJournal: { true })
        replacement.status = .notFound; events = []
        await unresolved.prepareForLaunch { events.append("restore") }
        assert(events == ["retire"] && unresolved.error != nil, "A missing helper with a restoration journal still requires recovery")

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
}
