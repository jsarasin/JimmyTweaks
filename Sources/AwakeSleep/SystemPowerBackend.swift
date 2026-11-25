import AppKit
import IOKit.pwr_mgt
import ServiceManagement

protocol PowerBackend: AnyObject {
    var helperAvailable: Bool { get }
    var helperStatus: String { get }
    var powerActionsAllowed: Bool { get }
    var helperDisabledUntilReset: Bool { get }
    var canConfigureHelper: Bool { get }
    var helperNeedsApproval: Bool { get }
    func refreshRecoveryState(completion: @escaping () -> Void)
    func configureHelper() throws
    func begin(session: UUID, closedLid: Bool, display: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    func setDisplayAwake(_ enabled: Bool) throws
    func renew(completion: @escaping (Result<Void, Error>) -> Void)
    func end(completion: @escaping (Result<Void, Error>) -> Void)
    func perform(_ action: PowerAction, completion: @escaping (Result<Void, Error>) -> Void)
    func prepareForUninstall(completion: @escaping (Result<Void, Error>) -> Void)
}

extension PowerBackend {
    var powerActionsAllowed: Bool { true }
    var helperDisabledUntilReset: Bool { false }
    var canConfigureHelper: Bool { !helperAvailable }
    var helperNeedsApproval: Bool { false }
    func refreshRecoveryState(completion: @escaping () -> Void) { completion() }
}

final class SystemPowerBackend: PowerBackend {
    private let service = SMAppService.daemon(plistName: PowerHelperIdentity.plistName)
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var connection: NSXPCConnection?
    private var helperSession: String?
    private var pendingReply: PowerHelperReplyGate?
    private var checkingRecovery = false
    private var lastRecoveryCheck: TimeInterval = -.infinity
    private let logger: FileLogger?
    private let workers: WorkerLifecycle
    init(workers: WorkerLifecycle = WorkerLifecycle(defaults: .standard), logger: FileLogger? = nil) {
        self.workers = workers; self.logger = logger
    }
    var powerActionsAllowed: Bool { !workers.restorationPending }
    var helperDisabledUntilReset: Bool { workers.disabledUntilReset }
    var canConfigureHelper: Bool { workers.canConfigure && !helperAvailable }
    var helperNeedsApproval: Bool { workers.needsApproval && !workers.disabledUntilReset }
    func refreshRecoveryState(completion: @escaping () -> Void) {
        guard workers.restorationPending, !checkingRecovery,
              ProcessInfo.processInfo.systemUptime - lastRecoveryCheck >= 5 else { return }
        checkingRecovery = true; lastRecoveryCheck = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.workers.refreshRestorationState()
            self.checkingRecovery = false; completion()
        }
    }

    private var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + PowerHelperIdentity.plistName).path)
    }
    var helperAvailable: Bool { bundled && !workers.preparing && !workers.disabledUntilReset && !workers.restorationPending && workers.error == nil && service.status == .enabled }
    var helperStatus: String {
        if workers.preparing { return "Updating the power helper…" }
        if workers.restorationPending {
            return "Sleep restoration is unresolved. Power actions are paused; the existing helper and recovery data have been retained. " + (workers.error ?? "")
        }
        if let error = workers.error { return error }
        guard bundled else { return "Closed-lid helper is unavailable in this build. Use the bundled Jimmy Tweaks application." }
        switch service.status {
        case .enabled: return "Closed-lid helper approved. Communication is verified when a session starts."
        case .requiresApproval: return "Approve Jimmy Tweaks in System Settings → General → Login Items & Extensions."
        case .notFound: return "macOS could not find the closed-lid helper. Use Set Up Closed-Lid Helper to try again with a signed, notarized build."
        case .notRegistered: return "Set up the closed-lid helper to keep a laptop awake with its lid closed. macOS requires a signed, notarized app and administrator approval."
        @unknown default: return "macOS returned an unknown helper status."
        }
    }
    func configureHelper() throws {
        do {
            guard canConfigureHelper else { throw PowerHelperFailure(kind: .unavailable, detail: helperStatus) }
            guard bundled else { throw PowerHelperFailure(kind: .incompatible, detail: helperStatus) }
            if service.status == .notRegistered || service.status == .notFound {
                try PowerHelperIdentity.validateInstallation()
                try service.register()
            }
            // Waiting for approval must preserve the existing update fingerprint and intent.
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
            guard service.status == .enabled else {
                throw PowerHelperFailure(kind: .unavailable, detail: "macOS did not enable the closed-lid helper. Closed-lid support is disabled until reset.")
            }
            // Startup owns replacement of an older installation. Setup must not mark it current.
            if workers.error == nil { try workers.rememberInstallation() }
        } catch {
            throw workers.configurationFailed(error)
        }
    }
    private func assertion(_ type: CFString) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Jimmy Tweaks — Awake & Sleep session" as CFString, &id)
        guard result == kIOReturnSuccess else { throw AwakeSleepError.message("macOS rejected the keep-awake assertion (\(result)).") }
        return id
    }
    func setDisplayAwake(_ enabled: Bool) throws {
        if enabled && displayAssertion == 0 { displayAssertion = try assertion(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString) }
        if !enabled && displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }
    private func releaseAssertions() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }
    func begin(session: UUID, closedLid: Bool, display: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard powerActionsAllowed else { throw PowerHelperFailure(kind: .restoration, detail: helperStatus) }
            systemAssertion = try assertion(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
            try setDisplayAwake(display)
            guard closedLid else { completion(.success(())); return }
            guard helperAvailable else { throw AwakeSleepError.message(helperStatus) }
            do { try connectHelper() }
            catch {
                releaseAssertions()
                Task { @MainActor in
                    await workers.handleFailure(error, operation: "connect-acquire")
                    completion(.failure(error))
                }
                return
            }
            helperSession = session.uuidString
            request("acquire", { $0.acquire(session.uuidString, withReply: $1) }) { [weak self] result in
                if case .failure = result {
                    // Invalidating also tells the helper to restore, even if its reply was lost.
                    self?.connection?.invalidate(); self?.connection = nil; self?.helperSession = nil
                    self?.releaseAssertions()
                }
                completion(result)
            }
        } catch { releaseAssertions(); completion(.failure(error)) }
    }
    private func connectHelper() throws {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/AwakeSleepHelper")
        let requirement = try PowerHelperIdentity.requirement(at: helperURL)
        let connection = NSXPCConnection(machServiceName: PowerHelperIdentity.service(for: .main), options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: AwakeSleepHelperProtocol.self)
        connection.resume(); self.connection = connection
    }
    func prepareForUninstall(completion: @escaping (Result<Void, Error>) -> Void) {
        guard connection == nil, helperSession == nil else { completion(.failure(AwakeSleepError.message("Cancel the active power session before uninstalling its helper."))); return }
        do {
            try connectHelper()
            request("prepare-uninstall", { $0.prepareForUninstall(withReply: $1) }) { [weak self] result in
                self?.connection?.invalidate(); self?.connection = nil
                completion(result)
            }
        } catch {
            Task { @MainActor in
                await workers.handleFailure(error, operation: "connect-uninstall")
                completion(.failure(error))
            }
        }
    }
    private func request(_ operation: String, _ send: (AwakeSleepHelperProtocol, @escaping (String?) -> Void) -> Void,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard let connection else { completion(.failure(PowerHelperFailure(kind: .unavailable, detail: "The closed-lid helper is disconnected."))); return }
        guard pendingReply == nil else { completion(.failure(AwakeSleepError.message("A power-helper request is already pending."))); return }
        logger?.log("power-helper", "request", "operation=\(operation)")
        let gate = PowerHelperReplyGate { [weak self] result in
            guard let self else { return }
            self.pendingReply = nil
            if case .failure(let error) = result {
                // Invalidate before any safety probe; a disconnected live helper can restore.
                self.connection?.invalidate(); self.connection = nil
                self.helperSession = nil
                self.logger?.log("power-helper", "request-failed", "operation=\(operation); \(error.localizedDescription)", severity: "WARN")
                Task { @MainActor in
                    await self.workers.handleFailure(error, operation: operation)
                    completion(result)
                }
            } else { completion(result) }
        }
        pendingReply = gate
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                gate.finish(.failure(PowerHelperFailure(kind: .unavailable,
                    detail: "The closed-lid helper connection failed (\((error as NSError).domain):\((error as NSError).code)). Sleep restoration has not been confirmed. Closed-lid support is disabled until reset.")))
            }
        } as! AwakeSleepHelperProtocol
        send(proxy) { error in
            DispatchQueue.main.async {
                gate.finish(error.map { .failure(PowerHelperFailure(kind: operation == "release" || operation == "prepare-uninstall" ? .restoration : .session, detail: $0)) } ?? .success(()))
            }
        }
    }
    func renew(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let helperSession else { completion(.success(())); return }
        guard helperAvailable else { completion(.failure(AwakeSleepError.message("Closed-lid helper approval was removed."))); return }
        request("renew", { $0.renew(helperSession, withReply: $1) }, completion: completion)
    }
    func end(completion: @escaping (Result<Void, Error>) -> Void) {
        releaseAssertions()
        guard let helperSession else { completion(.success(())); return }
        request("release", { $0.release(helperSession, withReply: $1) }) { [weak self] result in
            self?.connection?.invalidate(); self?.connection = nil; self?.helperSession = nil
            completion(result)
        }
    }
    func perform(_ action: PowerAction, completion: @escaping (Result<Void, Error>) -> Void) {
        guard powerActionsAllowed else { completion(.failure(PowerHelperFailure(kind: .restoration, detail: helperStatus))); return }
        if action == .sleep {
            let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            guard port != 0 else { completion(.failure(AwakeSleepError.message("macOS power management is unavailable."))); return }
            let status = IOPMSleepSystem(port); IOServiceClose(port)
            completion(status == kIOReturnSuccess ? .success(()) : .failure(AwakeSleepError.message("macOS rejected the sleep request (\(status)).")))
        } else if action == .shutDown {
            // Send the standard system-process event, allowing applications to veto quitting.
            // No root shutdown command or System Events automation permission is needed.
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
            var target = AEAddressDesc(), event = AppleEvent()
            var status = OSStatus(AECreateDesc(DescType(typeProcessSerialNumber), &psn, MemoryLayout.size(ofValue: psn), &target))
            defer { AEDisposeDesc(&target); AEDisposeDesc(&event) }
            if status == noErr { status = OSStatus(AECreateAppleEvent(AEEventClass(kCoreEventClass), AEEventID(kAEShutDown), &target, AEReturnID(kAutoGenerateReturnID), AETransactionID(kAnyTransactionID), &event)) }
            if status == noErr { status = AESendMessage(&event, nil, AESendMode(kAENoReply | kAECanInteract), 60) }
            completion(status == noErr ? .success(()) : .failure(AwakeSleepError.message("macOS rejected the shutdown request (\(status)).")))
        } else { completion(.success(())) }
    }
    deinit { connection?.invalidate(); releaseAssertions() }
}
