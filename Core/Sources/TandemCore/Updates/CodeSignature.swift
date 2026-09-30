import Foundation
import Security

/// Code-signing checks for updates: an update is only installed if Apple's code signing says it
/// is intact and was signed by the same developer team as the running app.
public enum CodeSignature {
    /// The Team ID the running app is signed with, or `nil` when it isn't signed by a team.
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    /// The Team ID the app at `url` is signed with.
    public static func teamIdentifier(ofAppAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Throws unless the app at `url` has a valid, complete signature from `teamIdentifier` for
    /// `bundleIdentifier`.
    public static func verify(appAt url: URL, bundleIdentifier: String, teamIdentifier: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.invalidPackage("The downloaded app couldn't be read.")
        }
        let text = "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.invalidPackage("Couldn't prepare the signature check.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.invalidPackage("The downloaded app isn't signed by the same developer as this one (code \(status)), so it wasn't installed.")
        }
    }
}
