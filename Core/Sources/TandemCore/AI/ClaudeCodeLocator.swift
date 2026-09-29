import Foundation

/// What Tandem knows about the Claude Code CLI on this Mac.
public struct ClaudeCodeStatus: Sendable, Hashable {
    public var executable: URL?
    public var version: String?
    public var signedIn: Bool
    /// The account the CLI is signed in with, when it says.
    public var account: String?
    /// The subscription type (e.g. "max", "enterprise"), when the CLI reports it.
    public var plan: String?

    public init(executable: URL? = nil, version: String? = nil, signedIn: Bool = false, account: String? = nil, plan: String? = nil) {
        self.executable = executable
        self.version = version
        self.signedIn = signedIn
        self.account = account
        self.plan = plan
    }

    public var isReady: Bool { executable != nil && signedIn }

    /// A one-line description for settings, or the fix when it isn't usable yet.
    public var summary: String {
        guard executable != nil else { return ClaudeCodeMessages.notFound }
        guard signedIn else { return ClaudeCodeMessages.signedOut }
        var parts = ["Claude Code \(version ?? "")".trimmingCharacters(in: .whitespaces)]
        if let account { parts.append("signed in as \(account)") } else { parts.append("signed in") }
        if let plan, !plan.isEmpty { parts.append("\(plan.capitalized) plan") }
        return parts.joined(separator: " · ")
    }
}

/// Finds the `claude` executable and checks whether it's signed in.
///
/// Apps don't inherit the shell's PATH, so the usual install locations are checked first and the
/// user's login shell is asked as a last resort.
public enum ClaudeCodeLocator {
    /// Where the installers put `claude`, most common first.
    public static func candidatePaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/claude",          // native installer
            "\(home)/.claude/local/claude",       // older per-user install
            "/opt/homebrew/bin/claude",           // Homebrew (Apple silicon), npm -g
            "/usr/local/bin/claude",              // Homebrew (Intel), npm -g
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude"
        ]
    }

    /// The executable at `override` or in a usual install location, without running anything.
    public static func quickLocate(override: String?, home: String = NSHomeDirectory()) -> URL? {
        let fileManager = FileManager.default
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return candidatePaths(home: home)
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Like ``quickLocate(override:home:)``, then asks the login shell (`command -v claude`).
    public static func locate(override: String?) async -> URL? {
        if let found = quickLocate(override: override) { return found }
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard let result = await ChildProcess.run(
            URL(fileURLWithPath: shell), arguments: ["-ilc", "command -v claude"], timeout: 5
        ), result.status == 0 else { return nil }
        let path = result.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Locates the CLI and asks it for its version and sign-in state.
    public static func status(override: String?) async -> ClaudeCodeStatus {
        guard let executable = await locate(override: override) else { return ClaudeCodeStatus() }
        let environment = ClaudeCodeClient.childEnvironment(
            from: ProcessInfo.processInfo.environment, executable: executable, maxOutputTokens: 1024
        )
        async let versionRun = ChildProcess.run(executable, arguments: ["--version"], environment: environment, timeout: 10)
        async let authRun = ChildProcess.run(executable, arguments: ["auth", "status"], environment: environment, timeout: 10)
        let (version, auth) = await (versionRun, authRun)
        var status = ClaudeCodeStatus(executable: executable)
        status.version = version.flatMap { parseVersion($0.output) }
        if let auth {
            apply(authStatus: auth.output, to: &status)
            if !status.signedIn {
                aiLogger.notice("claude auth status exited \(auth.status, privacy: .public) with \(auth.output.count, privacy: .public) bytes: \(auth.output.prefix(300), privacy: .public)")
            }
        } else if !Task.isCancelled {
            aiLogger.notice("claude auth status didn't finish")
        }
        return status
    }

    /// "2.1.285 (Claude Code)" → "2.1.285".
    static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// Reads the JSON printed by `claude auth status`.
    static func apply(authStatus output: String, to status: inout ClaudeCodeStatus) {
        guard let start = output.firstIndex(of: "{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(output[start...].utf8))) as? [String: Any] else { return }
        status.signedIn = object["loggedIn"] as? Bool ?? false
        status.account = object["email"] as? String
        status.plan = object["subscriptionType"] as? String
    }
}
