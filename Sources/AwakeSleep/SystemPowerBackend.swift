import AppKit
import IOKit.pwr_mgt
import ServiceManagement

protocol PowerBackend: AnyObject {
    var helperAvailable: Bool { get }
    var helperStatus: String { get }
    func configureHelper() throws
    func begin(session: UUID, closedLid: Bool, display: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    func setDisplayAwake(_ enabled: Bool) throws
    func renew(completion: @escaping (Result<Void, Error>) -> Void)
    func end(completion: @escaping (Result<Void, Error>) -> Void)
    func perform(_ action: PowerAction, completion: @escaping (Result<Void, Error>) -> Void)
    func prepareForUninstall(completion: @escaping (Result<Void, Error>) -> Void)
}

final class SystemPowerBackend: PowerBackend {
    private let service = SMAppService.daemon(plistName: PowerHelperIdentity.plistName)
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var connection: NSXPCConnection?
    private var helperSession: String?
    private var deadline: DispatchWorkItem?
    private var operationID = UUID()
    private let workers: WorkerLifecycle
    init(workers: WorkerLifecycle = WorkerLifecycle(defaults: .standard)) { self.workers = workers }

    private var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + PowerHelperIdentity.plistName).path)
    }
    var helperAvailable: Bool { bundled && !workers.preparing && workers.error == nil && service.status == .enabled }
    var helperStatus: String {
        if workers.preparing { return "Updating the power helper…" }
        if let error = workers.error { return error }
        guard bundled else { return "Closed-lid helper is unavailable in this build. Use the bundled Jimmy Tweaks application." }
        switch service.status {
        case .enabled: return "Closed-lid helper approved. Sessions can keep this Mac awake with its lid closed."
        case .requiresApproval: return "Approve Jimmy Tweaks in System Settings → General → Login Items & Extensions."
        case .notFound: return "macOS could not find the closed-lid helper. Use Set Up Closed-Lid Helper to try again with a signed, notarized build."
        case .notRegistered: return "Set up the closed-lid helper to keep a laptop awake with its lid closed. macOS requires a signed, notarized app and administrator approval."
        @unknown default: return "macOS returned an unknown helper status."
        }
    }
    func configureHelper() throws {
        guard bundled else { throw AwakeSleepError.message(helperStatus) }
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch { throw AwakeSleepError.message("macOS could not register the closed-lid helper. Launch daemons require a signed, notarized application; local ad-hoc builds may be rejected. " + error.localizedDescription) }
        }
        workers.rememberInstallation()
        if service.status != .enabled { SMAppService.openSystemSettingsLoginItems() }
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
            systemAssertion = try assertion(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
            try setDisplayAwake(display)
            guard closedLid else { completion(.success(())); return }
            guard helperAvailable else { throw AwakeSleepError.message(helperStatus) }
            try connectHelper(); helperSession = session.uuidString
            request({ $0.acquire(session.uuidString, withReply: $1) }) { [weak self] result in
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
            request({ $0.prepareForUninstall(withReply: $1) }) { [weak self] result in
                self?.connection?.invalidate(); self?.connection = nil
                completion(result)
            }
        } catch { completion(.failure(error)) }
    }
    private func request(_ send: (AwakeSleepHelperProtocol, @escaping (String?) -> Void) -> Void,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard let connection else { completion(.failure(AwakeSleepError.message("The closed-lid helper is disconnected."))); return }
        let id = UUID(); operationID = id
        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.operationID == id else { return }
                self.operationID = UUID(); self.deadline?.cancel(); self.deadline = nil
                completion(result)
            }
        }
        let timeout = DispatchWorkItem { finish(.failure(AwakeSleepError.message("The closed-lid helper did not respond. Its fail-safe will restore sleep after the lease expires."))) }
        deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        let proxy = connection.remoteObjectProxyWithErrorHandler { finish(.failure($0)) } as! AwakeSleepHelperProtocol
        send(proxy) { error in finish(error.map { .failure(AwakeSleepError.message($0)) } ?? .success(())) }
    }
    func renew(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let helperSession else { completion(.success(())); return }
        guard helperAvailable else { completion(.failure(AwakeSleepError.message("Closed-lid helper approval was removed."))); return }
        request({ $0.renew(helperSession, withReply: $1) }, completion: completion)
    }
    func end(completion: @escaping (Result<Void, Error>) -> Void) {
        releaseAssertions()
        guard let helperSession else { completion(.success(())); return }
        request({ $0.release(helperSession, withReply: $1) }) { [weak self] result in
            self?.connection?.invalidate(); self?.connection = nil; self?.helperSession = nil
            completion(result)
        }
    }
    func perform(_ action: PowerAction, completion: @escaping (Result<Void, Error>) -> Void) {
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
    deinit { deadline?.cancel(); connection?.invalidate(); releaseAssertions() }
}
