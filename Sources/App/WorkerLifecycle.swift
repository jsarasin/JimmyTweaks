import AppKit
import Security
import ServiceManagement

protocol ManagedWorkerService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

struct AppWorkerService: ManagedWorkerService {
    let service: SMAppService
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// Known app-owned registrations only. An update preserves user data; a factory
/// reset retires workers BEFORE removing the preference domain and local files.
final class WorkerLifecycle {
    static let installationKey = "workers.power.installation.v1"
    static let reinstallKey = "workers.power.reinstallPending.v2"
    static let legacyReinstallKey = "workers.power.reinstallPending"
    static let failureKey = "workers.power.failure.v1"
    static let disabledKey = "workers.power.disabledUntilReset.v1"
    static let setupFailedKey = "awakeSleep.helperSetupFailed"
    enum LaunchResult {
        case ready
        case helperUnavailable(PowerHelperFailure)
        case blocked(String)
    }
    private let defaults: UserDefaults
    private let power: ManagedWorkerService
    private let login: ManagedWorkerService
    private let identity: () throws -> String?
    private let retirePrevious: () async throws -> Void
    private let hasRecoveryJournal: () -> Bool
    private let readSleepDisabled: () async throws -> Bool
    private let validateInstallation: () throws -> Void
    private let log: (String, String) -> Void
    private(set) var preparing = false
    private(set) var result: LaunchResult = .ready
    private(set) var restorationPending = false
    var error: String? {
        switch result {
        case .ready: return nil
        case .helperUnavailable(let failure): return failure.detail
        case .blocked(let detail): return detail
        }
    }
    var blockingError: String? { if case .blocked(let detail) = result { return detail }; return nil }
    var disabledUntilReset: Bool {
        defaults.bool(forKey: Self.setupFailedKey) || defaults.bool(forKey: Self.disabledKey) || savedFailure?.untilReset == true
    }
    var needsApproval: Bool { power.status == .requiresApproval }
    var canConfigure: Bool { !preparing && !disabledUntilReset && (needsApproval || !restorationPending) }
    private var savedFailure: PowerHelperFailure? {
        guard let data = defaults.data(forKey: Self.failureKey) else { return nil }
        // Corrupt disablement state must not authorize silently reinstalling a daemon.
        return (try? JSONDecoder().decode(PowerHelperFailure.self, from: data)) ??
            PowerHelperFailure(kind: .unavailable, detail: "The saved helper failure could not be read. Closed-lid support is disabled until reset.")
    }
    init(defaults: UserDefaults, power: ManagedWorkerService = AppWorkerService(service: .daemon(plistName: PowerHelperIdentity.plistName)),
         login: ManagedWorkerService = AppWorkerService(service: .mainApp), identity: @escaping () throws -> String? = WorkerLifecycle.currentIdentity,
         retirePrevious: @escaping () async throws -> Void = { try await WorkerLifecycle.retirePreviousInstances() },
         hasRecoveryJournal: @escaping () -> Bool = WorkerLifecycle.hasRecoveryJournal,
         readSleepDisabled: @escaping () async throws -> Bool = { try await PowerHelperSafety.sleepDisabled() },
         validateInstallation: @escaping () throws -> Void = { try PowerHelperIdentity.validateInstallation() },
         log: @escaping (String, String) -> Void = { _, _ in }) {
        self.defaults = defaults; self.power = power; self.login = login; self.identity = identity
        self.retirePrevious = retirePrevious; self.hasRecoveryJournal = hasRecoveryJournal
        self.readSleepDisabled = readSleepDisabled; self.validateInstallation = validateInstallation; self.log = log
    }
    static func currentIdentity() throws -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/AwakeSleepHelper")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data else {
            throw PowerHelperFailure(kind: .incompatible, detail: "Could not verify the bundled worker's build identity. Reinstall a compatible signed build.")
        }
        return Bundle.main.bundleURL.resolvingSymlinksInPath().path + "|" + hash.map { String(format: "%02x", $0) }.joined()
    }
    static func hasRecoveryJournal() -> Bool {
        PowerHelperSafety.recoveryMayExist(at: "/var/db/" + PowerHelperIdentity.service(for: .main))
    }
    @MainActor static func retirePreviousInstances() async throws {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
        for app in others { _ = app.terminate() }
        for _ in 0..<100 {
            if others.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AwakeSleepError.message("An older Jimmy Tweaks instance is still running. Quit it, then reopen this version to finish updating workers.")
    }
    @MainActor func prepareForLaunch(preparePowerWorker: () async throws -> Void) async {
        preparing = true; defer { preparing = false }
        // Failure to retire another app is distinct from failure of an optional worker.
        do { try await retirePrevious() }
        catch { result = .blocked(error.localizedDescription); return }
        if disabledUntilReset || savedFailure?.kind == .restoration {
            result = .helperUnavailable(savedFailure ?? PowerHelperFailure(kind: .unavailable,
                detail: "Closed-lid support is disabled after a setup failure. Use Reset Permissions and Uninstall Workers to clear it."))
            restorationPending = true
            await refreshRestorationState()
            return
        }
        var restored = false
        do {
            guard let current = try identity() else {
                if hasRecoveryJournal() {
                    throw PowerHelperFailure(kind: .restoration, detail: "The power helper is missing and sleep restoration is unresolved. Install a compatible build to recover it.")
                }
                result = .ready; return
            }
            let previous = defaults.string(forKey: Self.installationKey)
            if defaults.bool(forKey: Self.legacyReinstallKey) {
                if previous != nil { defaults.set(true, forKey: Self.reinstallKey) }
                defaults.removeObject(forKey: Self.legacyReinstallKey)
            }
            // Pending recovery matters even when the binary has not changed.
            if power.status == .requiresApproval || power.status == .notFound {
                restorationPending = hasRecoveryJournal()
                if restorationPending || power.status == .requiresApproval {
                    result = .helperUnavailable(PowerHelperFailure(kind: power.status == .requiresApproval ? .approval : .restoration,
                        detail: power.status == .requiresApproval
                            ? "Approve the existing closed-lid helper in Login Items. Any pending replacement will wait for approval."
                            : "The closed-lid helper is missing and sleep restoration is unresolved. Install a compatible build to recover it."))
                } else { result = .ready }
                return
            }
            guard previous != current || defaults.bool(forKey: Self.reinstallKey) else { result = .ready; return }
            if power.status == .enabled {
                try await preparePowerWorker()
                restored = true; restorationPending = false
                // Never remove a working old worker just to install an incompatible build.
                try validateInstallation()
                defaults.set(true, forKey: Self.reinstallKey)
                try await power.unregister()
                try power.register()
                // Registration is not proof that the replacement can answer authenticated XPC.
                guard power.status == .enabled else {
                    throw PowerHelperFailure(kind: .approval, detail: "Approve the replacement closed-lid helper in Login Items, then reopen Jimmy Tweaks.")
                }
                try await preparePowerWorker()
            } else if power.status == .notRegistered && defaults.bool(forKey: Self.reinstallKey) {
                try validateInstallation()
                try power.register()
                guard power.status == .enabled else {
                    throw PowerHelperFailure(kind: .approval, detail: "Approve the replacement closed-lid helper in Login Items, then reopen Jimmy Tweaks.")
                }
                try await preparePowerWorker()
            } else if hasRecoveryJournal() {
                throw PowerHelperFailure(kind: .restoration, detail: "Sleep restoration is unresolved. A compatible approved helper is required before power actions can resume.")
            }
            defaults.removeObject(forKey: Self.reinstallKey)
            defaults.removeObject(forKey: Self.failureKey)
            defaults.set(current, forKey: Self.installationKey); result = .ready
        } catch { await handleFailure(error, operation: "update", retireIfSafe: true, restorationConfirmed: restored) }
    }
    @discardableResult func configurationFailed(_ error: Error) -> PowerHelperFailure {
        let failure = classify(error)
        if failure.kind != .approval && failure.kind != .session { save(failure) }
        result = .helperUnavailable(failure)
        restorationPending = hasRecoveryJournal()
        log("configure", failure.detail)
        return failure
    }
    private func classify(_ error: Error) -> PowerHelperFailure {
        let typed = error as? PowerHelperFailure
        if power.status == .requiresApproval, typed == nil || typed?.kind == .unavailable {
            return PowerHelperFailure(kind: .approval, detail: "Approve the closed-lid helper in Login Items, then reopen Jimmy Tweaks to resume any pending update.")
        }
        if let typed { return typed }
        return PowerHelperFailure(kind: .unavailable, detail: error.localizedDescription + " Closed-lid support is disabled until reset.")
    }
    private func save(_ failure: PowerHelperFailure) {
        if failure.untilReset { defaults.set(true, forKey: Self.disabledKey) }
        if let data = try? JSONEncoder().encode(failure) { defaults.set(data, forKey: Self.failureKey) }
    }
    @MainActor func handleFailure(_ error: Error, operation: String, retireIfSafe: Bool = false, restorationConfirmed: Bool = false) async {
        let failure = classify(error)
        if failure.kind != .approval && failure.kind != .session { save(failure) }
        result = .helperUnavailable(failure)
        restorationPending = !(restorationConfirmed && failure.kind == .incompatible)
        log(operation, "kind=\(failure.kind.rawValue); \(failure.detail)")
        await refreshRestorationState()
        // A timeout alone never authorizes removal. Both read-only checks must succeed.
        if retireIfSafe, failure.untilReset, !restorationPending, power.status == .enabled {
            do { try await power.unregister(); log("retire-failed-worker", "Removed after confirming no recovery state and SleepDisabled=0.") }
            catch { log("retire-failed-worker", error.localizedDescription) }
        }
    }
    @MainActor func refreshRestorationState() async {
        guard restorationPending else { return }
        guard !hasRecoveryJournal(), let disabled = try? await readSleepDisabled(), !disabled,
              !hasRecoveryJournal() else { return }
        restorationPending = false
        if case .helperUnavailable(let failure) = result, failure.kind == .session { result = .ready }
        log("restoration-confirmed", "No recovery state; SleepDisabled=0. Ordinary power actions are available.")
    }
    func rememberInstallation() throws {
        guard !disabledUntilReset, !restorationPending else {
            throw PowerHelperFailure(kind: .unavailable, detail: error ?? "Closed-lid support is disabled until reset.")
        }
        if let current = try identity() { defaults.set(current, forKey: Self.installationKey) }
        defaults.removeObject(forKey: Self.reinstallKey); defaults.removeObject(forKey: Self.legacyReinstallKey)
        defaults.removeObject(forKey: Self.failureKey); result = .ready
    }
    @MainActor func uninstall(preparePowerWorker: () async throws -> Void) async throws {
        var failures: [String] = []
        if power.status == .enabled {
            do {
                do { try await preparePowerWorker() }
                catch {
                    restorationPending = true; await refreshRestorationState()
                    guard !restorationPending else { throw error }
                }
                try await power.unregister()
            } catch { failures.append("Power helper: " + error.localizedDescription) }
        } else if hasRecoveryJournal() {
            failures.append("Approve or reinstall a compatible closed-lid helper so it can restore the saved sleep setting before reset.")
        } else if disabledUntilReset || savedFailure?.kind == .restoration {
            restorationPending = true; await refreshRestorationState()
            if restorationPending { failures.append("Sleep restoration could not be confirmed. Recovery data and settings have been retained.") }
            else if power.status != .notRegistered {
                do { try await power.unregister() } catch { failures.append("Power helper: " + error.localizedDescription) }
            }
        } else if power.status != .notRegistered {
            do { try await power.unregister() } catch { failures.append("Power helper: " + error.localizedDescription) }
        }
        if login.status != .notRegistered {
            do { try await login.unregister() } catch { failures.append("Launch at login: " + error.localizedDescription) }
        }
        guard failures.isEmpty else { throw AwakeSleepError.message(failures.joined(separator: "\n")) }
        for key in [Self.installationKey, Self.reinstallKey, Self.legacyReinstallKey, Self.failureKey, Self.setupFailedKey, Self.disabledKey] {
            defaults.removeObject(forKey: key)
        }
        restorationPending = false; result = .ready
    }

}

enum FreshInstallCleanup {
    static func directories(home: URL, bundleIdentifier: String) throws -> [URL] {
        _ = try PermissionResetter.arguments(bundleIdentifier: bundleIdentifier)
        return ["Library/Logs/Jimmy Tweaks", "Library/Caches/" + bundleIdentifier,
                "Library/Application Support/" + bundleIdentifier + "/RecurringRequests",
                "Library/Saved Application State/" + bundleIdentifier + ".savedState"].map { home.appendingPathComponent($0, isDirectory: true) }
    }
    static func removeUserData(bundleIdentifier: String, defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let paths = try directories(home: home, bundleIdentifier: bundleIdentifier)
        // Removing the app-specific domain clears shortcuts, onboarding, UI frames,
        // feature preferences, and worker fingerprints without changing global defaults.
        defaults.removePersistentDomain(forName: bundleIdentifier)
        guard defaults.synchronize() else { throw AwakeSleepError.message("macOS could not save the cleared preferences.") }
        for path in paths where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
