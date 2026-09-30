import Foundation
import TandemCore

/// Process-wide configuration. A launch argument `-TandemProfile <name>` isolates
/// defaults, Keychain items and data, so two instances can pair with each other on
/// one Mac (used for development and automated end-to-end checks).
enum AppEnvironment {
    static let profile: String? = {
        let value = UserDefaults.standard.string(forKey: "TandemProfile")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }()

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.rofel.tandem"

    static let defaults: UserDefaults = {
        guard let profile else { return .standard }
        return UserDefaults(suiteName: "\(bundleIdentifier).profile.\(profile)") ?? .standard
    }()

    static var keychainPrefix: String {
        profile.map { "\(bundleIdentifier).\($0)" } ?? bundleIdentifier
    }

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var url = base.appendingPathComponent("Tandem", isDirectory: true)
        if let profile { url = url.appendingPathComponent("Profiles/\(profile)", isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var threadsDirectory: URL { supportDirectory.appendingPathComponent("Threads", isDirectory: true) }
    static var snapshotsDirectory: URL { supportDirectory.appendingPathComponent("Snapshots", isDirectory: true) }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// The GitHub repository ("owner/name") whose releases Tandem updates from.
    static var updateRepository: String {
        (Bundle.main.object(forInfoDictionaryKey: "TandemUpdateRepository") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "RephaelCongmon/tandem"
    }

    /// Automatic update checks are off for development builds and profiles unless asked for.
    static var updatesEnabled: Bool {
        if UserDefaults.standard.bool(forKey: "TandemUpdateChecks") { return true }
        #if DEBUG
        return false
        #else
        return profile == nil
        #endif
    }

    /// Development builds are numbered 0.0.0 (see App/project.yml).
    static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Development-only: auto-approve pairing requests (never honored in Release).
    static var autoApprovePairing: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TANDEM_AUTO_APPROVE_PAIRING"] == "1"
        #else
        return false
        #endif
    }

    /// Development-only: the Studio pairs with the first Source it discovers.
    static var autoPair: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "TandemAutoPair")
        #else
        return false
        #endif
    }

    /// Development-only: keep streaming even when the Studio window is covered.
    static var ignoreOcclusion: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "TandemIgnoreOcclusion")
        #else
        return false
        #endif
    }

    /// Development-only: behave as if macOS opened Tandem as a login item.
    static var simulateLoginLaunch: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "TandemSimulateLoginLaunch")
        #else
        return false
        #endif
    }

    /// Development-only: the Source plays this sound file in a loop instead of capturing system
    /// audio (`-TandemTestAudio /path/to/file.aiff`).
    static var testAudioFile: URL? {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "TandemTestAudio"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        #else
        return nil
        #endif
    }

    /// Development-only: use SFSpeechRecognizer even where SpeechAnalyzer is available.
    static var preferLegacySpeech: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "TandemLegacySpeech")
        #else
        return false
        #endif
    }

    /// Development-only: override the AI base URL (e.g. a local mock server).
    static var debugAIBaseURL: URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TANDEM_AI_BASE_URL"].flatMap(URL.init(string:))
        #else
        return nil
        #endif
    }
}
