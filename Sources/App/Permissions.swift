import AppKit
import ApplicationServices

final class PermissionCoordinator {
    private(set) var accessibility = false
    private(set) var eventPosting = false
    var ready: Bool { accessibility && eventPosting }
    var summary: String {
        if !accessibility { return "Permission Required — allow Jimmy Tweaks to control windows." }
        if !eventPosting { return "Accessibility is granted. Waiting for macOS to make input control available; access is checked automatically." }
        return "Ready — window control and input interception are available."
    }
    private var timer: Timer?
    private var detailViewers = Set<String>()
    private var backgroundEligible = false
    private let checkAccessibility: () -> Bool
    private let checkEventPosting: () -> Bool
    private let requestEventPosting: () -> Bool
    init(checkAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
         checkEventPosting: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         requestEventPosting: @escaping () -> Bool = { CGRequestPostEventAccess() }) {
        self.checkAccessibility = checkAccessibility
        self.checkEventPosting = checkEventPosting
        self.requestEventPosting = requestEventPosting
        refresh()
    }
    deinit { timer?.invalidate() }
    func refresh(notify: Bool = true) {
        let ax = checkAccessibility()
        // Do not initialize the input-access check while Accessibility is denied.
        // On a fresh AX grant, ask Core Graphics to acquire input access as well:
        // polling its preflight alone can leave this process stuck waiting.
        var posting = ax && checkEventPosting()
        if ax && !accessibility && !posting {
            posting = requestEventPosting()
        }
        let changed = accessibility != ax || eventPosting != posting
        accessibility = ax; eventPosting = posting
        schedule()
        if changed && notify { NotificationCenter.default.post(name: .permissionsChanged, object: self) }
    }
    func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted && accessibility && !eventPosting { _ = requestEventPosting() }
        refresh()
    }
    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
    func setDetailed(_ id: String, visible: Bool) {
        if visible { detailViewers.insert(id) } else { detailViewers.remove(id) }
        schedule()
    }
    func setBackgroundEligible(_ eligible: Bool) { backgroundEligible = eligible; schedule() }
    private var interval: TimeInterval? {
        if !detailViewers.isEmpty { return 2 }
        guard backgroundEligible else { return nil }
        return ready ? 30 : 2
    }
    private var scheduledInterval: TimeInterval?
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
