import AppKit
#if RELEASE
import ServiceManagement
import Security
#endif

final class LoginService {
    let preferences: PreferenceStore
    private(set) var error: String?
    init(preferences: PreferenceStore) { self.preferences = preferences }
    #if RELEASE
    var available: Bool { true }
    var eligible: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let roots = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]
        guard roots.contains(where: { path.hasPrefix($0) }) else { return false }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first, let subject = SecCertificateCopySubjectSummary(certificate) as String? else { return false }
        return subject.hasPrefix("Developer ID Application:")
    }
    var enabled: Bool { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
    var explanation: String {
        if let error = error { return error }
        if !eligible { return "Move a Developer ID signed copy to Applications to use launch at login." }
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled. Login startup is silent and honors Suspend All. Quitting does not change this preference."
        case .requiresApproval: return "Waiting for your approval in System Settings → Login Items."
        case .notFound: return "The system could not find the installed application."
        case .notRegistered: return "Off. Jimmy Tweaks starts only when you open it."
        @unknown default: return "The system returned an unrecognized registration state."
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard eligible else { return }
        preferences.set(enabled, for: .loginRequested)
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = "Login registration could not be changed. The state shown is the system's actual state. \(error.localizedDescription)" }
        NotificationCenter.default.post(name: .runtimeChanged, object: self)
    }
    func reset() {
        guard eligible, SMAppService.mainApp.status != .notRegistered else { return }
        setEnabled(false)
    }
    #else
    var available: Bool { false }
    var eligible: Bool { false }
    var enabled: Bool { false }
    var explanation: String { "Open Jimmy Tweaks from Applications whenever you want to start it." }
    func setEnabled(_ enabled: Bool) {}
    func reset() {}
    #endif
}
