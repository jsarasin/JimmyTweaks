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
    static func requirement(at url: URL) throws -> String {
        var code: SecStaticCode?, requirement: SecRequirement?, result: CFString?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &result) == errSecSuccess, let result else {
            throw AwakeSleepError.message("The app or power helper has an invalid code signature. Rebuild or reinstall Jimmy Tweaks.")
        }
        return result as String
    }
}
