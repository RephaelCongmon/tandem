import Foundation

/// Finds command-line tools such as `claude` and `gh`. Apps don't inherit the shell's PATH, so the
/// usual install locations are checked first and the user's login shell is asked as a last resort.
public enum CommandLineTool {
    /// The first executable among `candidates`, or at `override` when one is given.
    public static func quickLocate(candidates: [String], override: String? = nil) -> URL? {
        let fileManager = FileManager.default
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return candidates
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Like ``quickLocate(candidates:override:)``, then asks the login shell for `name`.
    /// A non-empty `override` that doesn't exist is never silently replaced.
    public static func locate(_ name: String, candidates: [String], override: String? = nil) async -> URL? {
        if let found = quickLocate(candidates: candidates, override: override) { return found }
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard let result = await ChildProcess.run(
            URL(fileURLWithPath: shell), arguments: ["-ilc", "command -v \(name)"], timeout: 5
        ), result.status == 0 else { return nil }
        let path = result.output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
