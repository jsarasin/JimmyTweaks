import Foundation
import Security

@objc(AwakeSleepHelperProtocol) protocol AwakeSleepHelperProtocol {
    func acquire(_ session: String, withReply reply: @escaping (String?) -> Void)
    func renew(_ session: String, withReply reply: @escaping (String?) -> Void)
    func release(_ session: String, withReply reply: @escaping (String?) -> Void)
    func prepareForUninstall(withReply reply: @escaping (String?) -> Void)
}

enum PowerHelperIdentity {
    static let plistName = "AwakeSleepHelper.plist"
    static func service(for bundle: Bundle) -> String { (bundle.bundleIdentifier ?? "local.jimmytweaks.app") + ".power-helper" }
    static func validateInstallation(at url: URL = Bundle.main.bundleURL) throws {
        var code: SecStaticCode?, information: CFDictionary?, anchor: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &anchor) == errSecSuccess, let anchor,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], anchor) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first,
              (SecCertificateCopySubjectSummary(certificate) as String?)?.hasPrefix("Developer ID Application:") == true else {
            throw PowerHelperFailure(kind: .incompatible, detail: "Closed-lid support requires a valid Developer ID signed, notarized installation. Reinstall a compatible build; other Jimmy Tweaks features remain available.")
        }
    }
    static func requirement(at url: URL) throws -> String {
        var code: SecStaticCode?, requirement: SecRequirement?, result: CFString?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &result) == errSecSuccess, let result else {
            throw PowerHelperFailure(kind: .incompatible, detail: "The app or power helper has an invalid code signature. Rebuild or reinstall Jimmy Tweaks.")
        }
        return result as String
    }
}
