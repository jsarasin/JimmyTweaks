import AppKit
import ApplicationServices
import IOKit.hidsystem

/// Native listening access can also be supplied by Accessibility. A successful
/// check does not prove the separate Input Monitoring switch is enabled.
struct InputMonitoringAccess {
    var checkAccess: (IOHIDRequestType) -> IOHIDAccessType = IOHIDCheckAccess
    var requestAccess: (IOHIDRequestType) -> Bool = IOHIDRequestAccess

    func isGranted() -> Bool { checkAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    func request() -> Bool { requestAccess(kIOHIDRequestTypeListenEvent) }
}

final class PermissionCoordinator {
    private(set) var accessibility = false
    private(set) var eventPosting = false
    private(set) var inputMonitoring = false
    private(set) var screenRecording = false
    private var startupNoticeShown = false
    private var terminating = false
    var ready: Bool { accessibility && eventPosting }
    var allGranted: Bool { ready && (inputMonitoring || accessibility) && screenRecording }
    var summary: String {
        if !accessibility { return "Permission Required — allow Jimmy Tweaks to control windows." }
        if !eventPosting { return "Device Control and Data Access is approved, but input control is unavailable. Use Request in Permissions or restart Jimmy Tweaks." }
        return "Ready — window control and input interception are available."
    }
    private var timer: Timer?
    private var detailViewers = Set<String>()
    private var backgroundEligible = false
    private let checkAccessibility: () -> Bool
    private let checkEventPosting: () -> Bool
    private let requestEventPosting: () -> Bool
    private let checkListening: () -> Bool
    private let requestListening: () -> Bool
    private let checkScreenRecording: () -> Bool
    private let requestAccessibility: () -> Bool
    private let requestScreenRecording: () -> Bool
    private let settingsOpener: (URL) -> Bool
    init(checkAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
         checkEventPosting: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         requestEventPosting: @escaping () -> Bool = { CGRequestPostEventAccess() },
         checkListening: (() -> Bool)? = nil,
         requestListening: (() -> Bool)? = nil,
         checkScreenRecording: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         requestAccessibility: @escaping () -> Bool = {
             AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
         },
         requestScreenRecording: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         inputMonitoringAccess: InputMonitoringAccess = InputMonitoringAccess(),
         settingsOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.checkAccessibility = checkAccessibility
        self.checkEventPosting = checkEventPosting
        self.requestEventPosting = requestEventPosting
        self.checkListening = checkListening ?? { inputMonitoringAccess.isGranted() }
        self.requestListening = requestListening ?? { inputMonitoringAccess.request() }
        self.checkScreenRecording = checkScreenRecording
        self.requestAccessibility = requestAccessibility
        self.requestScreenRecording = requestScreenRecording
        self.settingsOpener = settingsOpener
        refresh()
    }
    deinit { timer?.invalidate() }
    func refresh(notify: Bool = true) {
        guard !terminating else { return }
        let ax = checkAccessibility()
        // Checks must never request access, including after a fresh AX grant.
        let posting = ax && checkEventPosting()
        let listening = checkListening()
        let recording = checkScreenRecording()
        let changed = accessibility != ax || eventPosting != posting || inputMonitoring != listening || screenRecording != recording
        screenRecording = recording
        inputMonitoring = listening
        accessibility = ax; eventPosting = posting
        schedule()
        if changed && notify { NotificationCenter.default.post(name: .permissionsChanged, object: self) }
    }
    var missingPermissions: [PermissionEntry] {
        PermissionEntry.allCases.filter { permission in
            switch permission {
            case .accessibility: return !accessibility
            case .inputMonitoring: return !inputMonitoring && !accessibility
            case .screenRecording: return !screenRecording
            }
        }
    }
    /// Inform once per launch, including login launches. No system request is made.
    func showStartupNotice(present: (String, String) -> Void) {
        guard !terminating, !startupNoticeShown else { return }
        startupNoticeShown = true
        refresh()
        let missing = missingPermissions
        guard !missing.isEmpty else { return }
        present("Permissions Not Approved", "The following permissions are not approved for Jimmy Tweaks:\n\n" +
                missing.map { "• \($0.title)" }.joined(separator: "\n") +
                "\n\nOpen Permissions in Jimmy Tweaks to request access and check for approval.")
    }
    /// Only explicit user actions may call this. A request is not an approval;
    /// macOS may suppress prompts after denial, so recheck the observed grants.
    func request(_ permission: PermissionEntry) {
        guard !terminating else { return }
        refresh()
        switch permission {
        case .accessibility:
            if !accessibility { _ = requestAccessibility() }
            refresh()
            if accessibility && !eventPosting { _ = requestEventPosting() }
        case .inputMonitoring:
            // Always send an explicit request. Effective listening access may be
            // inherited from AX while this app is absent from Input Monitoring.
            _ = requestListening()
        case .screenRecording:
            if !screenRecording { _ = requestScreenRecording() }
        }
        refresh()
    }
    func openSettings(for permission: PermissionEntry) {
        switch permission {
        case .accessibility: openSettings()
        case .inputMonitoring: openInputMonitoringSettings()
        case .screenRecording: openScreenRecordingSettings()
        }
    }
    @discardableResult func openInputMonitoringSettings() -> Bool {
        settingsOpener(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
    func stopMonitoringForTermination() {
        terminating = true; timer?.invalidate(); timer = nil; scheduledInterval = nil
    }
    func setDetailed(_ id: String, visible: Bool) {
        if visible { detailViewers.insert(id) } else { detailViewers.remove(id) }
        schedule()
    }
    func setBackgroundEligible(_ eligible: Bool) { backgroundEligible = eligible; schedule() }
    private var interval: TimeInterval? {
        guard !terminating else { return nil }
        if !detailViewers.isEmpty { return allGranted ? 30 : 2 }
        guard backgroundEligible else { return nil }
        return ready ? 30 : 2
    }
    private var scheduledInterval: TimeInterval?
    #if TESTING
    var pollingIntervalForTesting: TimeInterval? { scheduledInterval }
    #endif
    private func schedule() {
        guard scheduledInterval != interval else { return }
        timer?.invalidate(); timer = nil; scheduledInterval = interval
        if let interval = interval {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = interval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}

/// Uses the supported, app-scoped TCC reset command. Never invoke without a valid
/// bundle identifier: omitting it would reset the selected service for every app.
enum PermissionResetter {
    struct Output { let status: Int32; let errorText: String }
    typealias Executor = (URL, [String]) async throws -> Output
    enum Failure: LocalizedError {
        case missingIdentity, rejected(Int32, String), timeout
        var errorDescription: String? {
            switch self {
            case .missingIdentity: return "This build has no valid bundle identifier. Refusing to reset permissions without an app-specific identity."
            case .rejected(let status, let detail): return "macOS did not complete the permission reset (exit \(status))." + (detail.isEmpty ? "" : " \(detail)")
            case .timeout: return "The macOS permission reset did not finish within 10 seconds. Relaunch Jimmy Tweaks before trying again."
            }
        }
    }
    static func arguments(bundleIdentifier: String?) throws -> [String] {
        guard let identifier = bundleIdentifier, identifier.count <= 255,
              identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9][A-Za-z0-9-]*)+$", options: .regularExpression) != nil else { throw Failure.missingIdentity }
        return ["reset", "All", identifier]
    }
    static func reset(bundleIdentifier: String?, execute: Executor = executeProcess) async throws {
        let arguments = try arguments(bundleIdentifier: bundleIdentifier)
        let output = try await execute(URL(fileURLWithPath: "/usr/bin/tccutil"), arguments)
        guard output.status == 0 else { throw Failure.rejected(output.status, output.errorText) }
    }
    private static func executeProcess(_ executable: URL, _ arguments: [String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process(), pipe = Pipe(), diagnostics = Locked(Data()), timedOut = Locked(false)
            process.executableURL = executable; process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                diagnostics.withValue { $0.append(data.prefix(max(0, 2048 - $0.count))) }
            }
            let deadline = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOut.withValue { $0 = true }; process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                }
            }
            process.terminationHandler = { process in
                deadline.cancel(); pipe.fileHandleForReading.readabilityHandler = nil
                let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
                diagnostics.withValue { $0.append(remainder.prefix(max(0, 2048 - $0.count))) }
                if timedOut.snapshot { continuation.resume(throwing: Failure.timeout) }
                else { continuation.resume(returning: Output(status: process.terminationStatus, errorText: String(decoding: diagnostics.snapshot, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil; process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
