import Foundation
import Security
import SystemConfiguration
import Darwin
import os

/// Root-only implementation. All state, including XPC calls and watchdog recovery,
/// is serialized on the main queue. The protocol never accepts executable paths or commands.
final class PowerHelper: NSObject, NSXPCListenerDelegate {
    private let journalURL: URL
    private let lease: ClosedLidLease
    private var leaseConnection: NSXPCConnection?
    private var leaseUID: uid_t?
    private var timer: DispatchSourceTimer?
    private var termination: DispatchSourceSignal?

    static func pmset(_ arguments: [String]) throws -> String {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        task.standardOutput = output; task.standardError = output
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        try task.run()
        if done.wait(timeout: .now() + 3) == .timedOut {
            task.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut { kill(task.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 0.5) }
            throw AwakeSleepError.message("Power management did not respond in time. Restoration will be retried.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard task.terminationStatus == 0 else { throw AwakeSleepError.message("pmset rejected the power setting (\(task.terminationStatus)).") }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func sleepDisabled() throws -> Bool {
        try PowerHelperSafety.parseSleepDisabled(pmset(["-g"]))
    }
    private static func ensureDirectory(_ directory: URL) throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw AwakeSleepError.message("Could not create the sleep restoration journal directory.") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0, (info.st_mode & 0o077) == 0 else {
            throw AwakeSleepError.message("The sleep restoration journal directory is not root-owned and private.")
        }
    }
    init(service: String) throws {
        guard service.count <= 255, service.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw AwakeSleepError.message("Invalid power-helper service identity.")
        }
        let directory = URL(fileURLWithPath: "/var/db/" + service, isDirectory: true)
        try Self.ensureDirectory(directory)
        journalURL = directory.appendingPathComponent("restore.json")
        helperLog.info("startup stage=journal-open")
        let url = journalURL
        lease = ClosedLidLease(read: Self.sleepDisabled, write: { value in
            _ = try Self.pmset(["-a", "disablesleep", value ? "1" : "0"])
            guard try Self.sleepDisabled() == value else { throw AwakeSleepError.message("macOS did not apply the closed-lid sleep setting.") }
        }, journal: { original in
            if let original {
                try Self.ensureDirectory(directory)
                let data = try JSONEncoder().encode(original)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
                let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                if fd >= 0 { defer { close(fd) }; guard fsync(fd) == 0 else { throw AwakeSleepError.message("Could not sync the restoration journal.") } }
            } else {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                if rmdir(directory.path) != 0 && errno != ENOENT { throw AwakeSleepError.message("Could not remove the sleep restoration journal directory.") }
            }
        }, now: { ProcessInfo.processInfo.systemUptime })
        super.init()
        if FileManager.default.fileExists(atPath: journalURL.path) {
            // Preserve a corrupt journal for diagnosis; never guess the prior system setting.
            helperLog.info("startup stage=journal-recovery")
            let original = try JSONDecoder().decode(Bool.self, from: Data(contentsOf: journalURL))
            do { try lease.recover(original: original) } catch { helperLog.error("recovery pending domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public) detail=\(error.localizedDescription, privacy: .private)") }
        } else { _ = rmdir(directory.path) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.watchdog() }
        timer.resume(); self.timer = timer
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { [weak self] in
            do { try self?.lease.release(); exit(0) }
            catch { NSLog("Termination restoration failed: %@", error.localizedDescription); exit(1) }
        }
        termination.resume(); self.termination = termination
    }
    private static func consoleUID() -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, user != "loginwindow", uid != 0 else { return nil }
        return uid
    }
    private func watchdog() {
        do {
            if let leaseUID, leaseUID != Self.consoleUID() { try lease.release(); self.leaseUID = nil; leaseConnection = nil }
            try lease.tick()
            if lease.owner == nil { leaseUID = nil; leaseConnection = nil }
        } catch { NSLog("Sleep restoration failed; retrying: %@", error.localizedDescription) }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0, connection.effectiveUserIdentifier == Self.consoleUID() else { return false }
        let endpoint = PowerEndpoint(helper: self, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: AwakeSleepHelperProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self, let connection, self.leaseConnection === connection else { return }
                do { try self.lease.release() } catch { NSLog("Disconnected client restoration pending: %@", error.localizedDescription) }
                self.leaseConnection = nil; self.leaseUID = nil
            }
        }
        connection.resume(); return true
    }
    func handle(_ operation: String, session: String, connection: NSXPCConnection, reply: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard UUID(uuidString: session) != nil, connection.effectiveUserIdentifier == Self.consoleUID() else { reply("The session is invalid or this user is no longer active."); return }
        do {
            if operation == "acquire" {
                guard leaseConnection == nil || leaseConnection === connection else { throw AwakeSleepError.message("A different session already owns the closed-lid override.") }
                try lease.acquire(owner: session); leaseConnection = connection; leaseUID = connection.effectiveUserIdentifier
            } else {
                guard leaseConnection === connection else {
                    // Releasing a lost/expired lease is idempotent, but must not affect another owner.
                    if operation == "release", lease.owner == nil { reply(nil); return }
                    throw AwakeSleepError.message("This connection does not own the closed-lid session.")
                }
                if operation == "renew" { try lease.renew(owner: session) }
                else { try lease.release(owner: session); leaseConnection = nil; leaseUID = nil }
            }
            reply(nil)
        } catch { reply(error.localizedDescription) }
    }
    func prepareForUninstall(connection: NSXPCConnection, reply: @escaping (String?) -> Void) {
        guard connection.effectiveUserIdentifier == Self.consoleUID() else { reply("Only the active user can remove the power helper."); return }
        do {
            try lease.release(); leaseConnection = nil; leaseUID = nil
            let directory = journalURL.deletingLastPathComponent()
            if rmdir(directory.path) != 0 && errno != ENOENT { throw AwakeSleepError.message("Could not remove the power helper's restoration directory.") }
            reply(nil)
        } catch { reply(error.localizedDescription) }
    }
}

final class PowerEndpoint: NSObject, AwakeSleepHelperProtocol {
    private weak var helper: PowerHelper?
    private weak var connection: NSXPCConnection?
    init(helper: PowerHelper, connection: NSXPCConnection) { self.helper = helper; self.connection = connection }
    private func send(_ operation: String, _ session: String, _ reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let helper = self.helper, let connection = self.connection else { reply("Power helper disconnected."); return }
            helper.handle(operation, session: session, connection: connection, reply: reply)
        }
    }
    func acquire(_ session: String, withReply reply: @escaping (String?) -> Void) { send("acquire", session, reply) }
    func renew(_ session: String, withReply reply: @escaping (String?) -> Void) { send("renew", session, reply) }
    func release(_ session: String, withReply reply: @escaping (String?) -> Void) { send("release", session, reply) }
    func prepareForUninstall(withReply reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let helper = self.helper, let connection = self.connection else { reply("Power helper disconnected."); return }
            helper.prepareForUninstall(connection: connection, reply: reply)
        }
    }
}

private let helperLog = Logger(subsystem: "local.jimmytweaks.power-helper", category: "lifecycle")

guard geteuid() == 0 else { fputs("AwakeSleepHelper must be launched by macOS as an approved daemon.\n", stderr); exit(1) }
var stage = "executable-location"
var recoveryPath: String?
do {
    helperLog.info("startup stage=executable-location")
    let appURL = try PowerHelperSafety.enclosingApp(executable: PowerHelperSafety.executableURL())
    stage = "bundle-validation"
    guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier,
          bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
        throw AwakeSleepError.message("The helper has no valid enclosing application identity.")
    }
    let service = PowerHelperIdentity.service(for: bundle)
    // Establish the recovery location before any signature check can fail.
    recoveryPath = "/var/db/" + service
    helperLog.info("startup stage=bundle-validation path=\(appURL.path, privacy: .private)")
    stage = "journal-recovery"
    let helper = try PowerHelper(service: service)
    stage = "signature-validation"
    helperLog.info("startup stage=signature-validation")
    let requirement = try PowerHelperIdentity.requirement(at: appURL)
    stage = "listener-setup"
    let listener = NSXPCListener(machServiceName: service)
    // Enforced by XPC for every message, including across exec/PID reuse.
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = helper; listener.resume()
    helperLog.info("startup stage=listener-ready")
    withExtendedLifetime((helper, listener)) { dispatchMain() }
} catch {
    // An unknown recovery location must never suppress recovery restarts.
    let recovery = recoveryPath.map { PowerHelperSafety.recoveryMayExist(at: $0) } ?? true
    let code = PowerHelperSafety.terminalExitCode(recoveryMayExist: recovery)
    helperLog.error("startup-failed stage=\(stage, privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public) recovery=\(recovery, privacy: .public) exit=\(code, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
    exit(code)
}
