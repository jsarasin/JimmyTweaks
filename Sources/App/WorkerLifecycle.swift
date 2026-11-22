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
    private let defaults: UserDefaults
    private let power: ManagedWorkerService
    private let login: ManagedWorkerService
    private let identity: () throws -> String?
    private let retirePrevious: () async throws -> Void
    private let hasRecoveryJournal: () -> Bool
    private(set) var preparing = false
    private(set) var error: String?
    init(defaults: UserDefaults, power: ManagedWorkerService = AppWorkerService(service: .daemon(plistName: PowerHelperIdentity.plistName)),
         login: ManagedWorkerService = AppWorkerService(service: .mainApp), identity: @escaping () throws -> String? = WorkerLifecycle.currentIdentity,
         retirePrevious: @escaping () async throws -> Void = { try await WorkerLifecycle.retirePreviousInstances() },
         hasRecoveryJournal: @escaping () -> Bool = WorkerLifecycle.hasRecoveryJournal) {
        self.defaults = defaults; self.power = power; self.login = login; self.identity = identity
        self.retirePrevious = retirePrevious; self.hasRecoveryJournal = hasRecoveryJournal
    }
    static func currentIdentity() throws -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/AwakeSleepHelper")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data else {
            throw AwakeSleepError.message("Could not verify the bundled worker's build identity.")
        }
        return Bundle.main.bundleURL.resolvingSymlinksInPath().path + "|" + hash.map { String(format: "%02x", $0) }.joined()
    }
    static func hasRecoveryJournal() -> Bool {
        FileManager.default.fileExists(atPath: "/var/db/" + PowerHelperIdentity.service(for: .main))
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
        do {
            guard let current = try identity() else { return }
            try await retirePrevious()
            let previous = defaults.string(forKey: Self.installationKey)
            if defaults.bool(forKey: Self.legacyReinstallKey) {
                // Older builds set this before trying to unregister even a missing
                // helper. Without an installation record it is not update intent.
                if previous != nil { defaults.set(true, forKey: Self.reinstallKey) }
                defaults.removeObject(forKey: Self.legacyReinstallKey)
            }
            guard previous != current || defaults.bool(forKey: Self.reinstallKey) else { error = nil; return }
            if power.status == .enabled {
                try await preparePowerWorker()
                defaults.set(true, forKey: Self.reinstallKey)
                // The completion form waits until the old process is actually reaped.
                try await power.unregister()
                try power.register()
            } else if power.status == .requiresApproval || power.status == .notFound {
                guard !hasRecoveryJournal() else { throw AwakeSleepError.message("Approve the existing closed-lid helper in Login Items so it can restore sleep before the update. Then reopen Jimmy Tweaks.") }
                // Neither status authorizes replacing a worker: notFound can mean
                // this build has never registered one, and requiresApproval also
                // covers a helper the user deliberately disabled. Leave setup to
                // Awake & Sleep and retry an existing update after approval.
                error = nil
                return
            } else if power.status == .notRegistered && defaults.bool(forKey: Self.reinstallKey) {
                // Recover an update interrupted after unregistering the previous executable.
                try power.register()
            }
            defaults.removeObject(forKey: Self.reinstallKey)
            defaults.set(current, forKey: Self.installationKey); error = nil
        } catch { self.error = "Worker update incomplete. " + error.localizedDescription }
    }
    func rememberInstallation() {
        do { if let current = try identity() { defaults.set(current, forKey: Self.installationKey) }; defaults.removeObject(forKey: Self.reinstallKey); defaults.removeObject(forKey: Self.legacyReinstallKey); error = nil }
        catch { self.error = error.localizedDescription }
    }
    @MainActor func uninstall(preparePowerWorker: () async throws -> Void) async throws {
        var failures: [String] = []
        if power.status == .enabled {
            do { try await preparePowerWorker(); try await power.unregister() }
            catch { failures.append("Power helper: " + error.localizedDescription) }
        } else if hasRecoveryJournal() {
            failures.append("Set up and approve the closed-lid helper in Awake & Sleep / Login Items, then retry so its saved sleep setting can be restored.")
        } else if power.status != .notRegistered {
            do { try await power.unregister() } catch { failures.append("Power helper: " + error.localizedDescription) }
        }
        if login.status != .notRegistered {
            do { try await login.unregister() } catch { failures.append("Launch at login: " + error.localizedDescription) }
        }
        if power.status == .notRegistered {
            defaults.removeObject(forKey: Self.reinstallKey)
            defaults.removeObject(forKey: Self.legacyReinstallKey)
        }
        guard failures.isEmpty else { throw AwakeSleepError.message(failures.joined(separator: "\n")) }
        defaults.removeObject(forKey: Self.installationKey)
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
