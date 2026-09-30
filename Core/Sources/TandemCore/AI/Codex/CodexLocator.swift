import Foundation

public enum CodexMessages {
    public static let notFound = "Codex isn't installed on this Mac. Install it with `brew install --cask codex` (or from chatgpt.com/codex), or set its location in Settings › AI."
    public static let signedOut = "Codex isn't signed in. Open Terminal, run `codex login`, and sign in with your ChatGPT account."
    public static let modelUnavailable = "Your ChatGPT plan can't use this model through Codex. Pick another one in Settings › AI."
}

/// What Tandem knows about the Codex CLI on this Mac.
public struct CodexStatus: Sendable, Hashable {
    public var executable: URL?
    public var version: String?
    public var signedIn: Bool
    /// How it's signed in, as Codex says it ("ChatGPT" or "an API key").
    public var method: String?

    public init(executable: URL? = nil, version: String? = nil, signedIn: Bool = false, method: String? = nil) {
        self.executable = executable
        self.version = version
        self.signedIn = signedIn
        self.method = method
    }

    public var isReady: Bool { executable != nil && signedIn }

    /// Signed in with a ChatGPT account (so questions count toward the ChatGPT plan).
    public var usesChatGPT: Bool { method?.localizedCaseInsensitiveContains("chatgpt") ?? false }

    public var summary: String {
        guard executable != nil else { return CodexMessages.notFound }
        guard signedIn else { return CodexMessages.signedOut }
        let name = "Codex \(version ?? "")".trimmingCharacters(in: .whitespaces)
        if usesChatGPT { return "\(name) · signed in with ChatGPT" }
        if let method { return "\(name) · signed in with \(method)" }
        return "\(name) · signed in"
    }
}

/// Finds the `codex` executable and checks whether it's signed in.
public enum CodexLocator {
    public static func candidatePaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin/codex",            // Homebrew cask (Apple silicon), npm -g
            "/usr/local/bin/codex",               // Homebrew (Intel), npm -g
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.volta/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
    }

    public static func quickLocate(override: String?, home: String = NSHomeDirectory()) -> URL? {
        CommandLineTool.quickLocate(candidates: candidatePaths(home: home), override: override)
    }

    public static func locate(override: String?) async -> URL? {
        await CommandLineTool.locate("codex", candidates: candidatePaths(), override: override)
    }

    public static func status(override: String?) async -> CodexStatus {
        guard let executable = await locate(override: override) else { return CodexStatus() }
        let environment = CodexLaunch.environment(executable: executable)
        async let versionRun = ChildProcess.run(executable, arguments: ["--version"], environment: environment, timeout: 10)
        async let loginRun = ChildProcess.run(executable, arguments: ["login", "status"], environment: environment, timeout: 15)
        let (version, login) = await (versionRun, loginRun)
        var status = CodexStatus(executable: executable)
        status.version = version.flatMap { parseVersion($0.output) }
        if let login {
            // `codex login status` prints to stdout or stderr depending on the version.
            apply(loginStatus: login.output + "\n" + login.errors, exitStatus: login.status, to: &status)
        }
        return status
    }

    /// "codex-cli 0.159.2" → "0.159.2".
    static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).last { $0.first?.isNumber == true }.map(String.init)
    }

    /// "Logged in using ChatGPT" / "Logged in using an API key - sk-…" / "Not logged in".
    static func apply(loginStatus output: String, exitStatus: Int32, to status: inout CodexStatus) {
        guard let line = output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.localizedCaseInsensitiveContains("logged in") }) else {
            status.signedIn = false
            return
        }
        if line.lowercased().hasPrefix("not logged in") || exitStatus != 0 {
            status.signedIn = false
            return
        }
        status.signedIn = true
        if let range = line.range(of: "using ", options: .caseInsensitive) {
            var method = String(line[range.upperBound...])
            // Never keep (part of) an API key.
            if let dash = method.range(of: " - ") { method = String(method[..<dash.lowerBound]) }
            status.method = method.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// How Tandem starts `codex app-server`: a clean slate like Claude Code's `--safe-mode`. No tools
/// (shell, code execution, browser, apps, plugins, MCP servers, web search), so the model can only
/// answer. Only switches this Codex version knows are passed, because unknown ones are errors.
public enum CodexLaunch {
    /// Features that give the model tools or pull in the user's own setup.
    public static let disabledFeatures = [
        "shell_tool", "unified_exec", "view_image", "apps", "browser_use", "browser_use_external", "computer_use",
        "image_generation", "multi_agent", "plugins", "in_app_browser", "skill_search", "tool_suggest", "sleep_tool",
        "realtime_conversation", "goals", "memories", "workspace_dependencies", "worktrees", "shell_snapshot", "hooks",
        "code_mode_host"
    ]

    static func environment(executable: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        // The ChatGPT sign-in is what Tandem wants; a stray API key would bill it instead.
        environment["OPENAI_API_KEY"] = nil
        environment["CODEX_API_KEY"] = nil
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + path
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// Names from `codex features list` (the first column of each row).
    static func parseFeatures(_ output: String) -> Set<String> {
        // Rows look like "shell_tool   stable   true".
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 3, let enabled = columns.last, enabled == "true" || enabled == "false",
                  columns[0].range(of: #"^[a-z0-9_.]+$"#, options: .regularExpression) != nil else { return nil }
            return columns[0]
        })
    }

    /// Top-level MCP server ids in a Codex `config.toml` (`[mcp_servers.<id>]`).
    static func mcpServerIDs(inConfig text: String) -> [String] {
        var ids: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[") else { continue }
            let key = String(trimmed.dropFirst("[mcp_servers.".count).dropLast())
            let id: String
            if key.hasPrefix("\"") {
                guard let close = key.dropFirst().firstIndex(of: "\""), key[key.index(after: close)...].isEmpty else { continue }
                id = String(key.dropFirst()[..<close])
            } else {
                guard !key.contains("."), !key.isEmpty else { continue }
                id = key
            }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Where Codex keeps its config.
    static func codexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty { return URL(fileURLWithPath: (home as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The `codex app-server` arguments for this Mac's Codex.
    static func arguments(knownFeatures: Set<String>, mcpServers: [String]) -> [String] {
        var arguments = ["app-server"]
        for feature in disabledFeatures where knownFeatures.contains(feature) {
            arguments += ["--disable", feature]
        }
        arguments += ["-c", "web_search=\"disabled\""]
        if knownFeatures.contains("code_mode") || knownFeatures.contains("code_mode_host") {
            arguments += ["-c", "features.code_mode.enabled=false"]
        }
        for server in mcpServers {
            let key = server.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil ? server : "\"\(server)\""
            arguments += ["-c", "mcp_servers.\(key).enabled=false"]
        }
        return arguments
    }

    /// Asks the installed Codex which features it has and reads the user's MCP servers.
    static func resolveArguments(executable: URL) async -> [String] {
        let environment = environment(executable: executable)
        var features = Set<String>()
        if let result = await ChildProcess.run(executable, arguments: ["features", "list"], environment: environment, timeout: 15), result.status == 0 {
            features = parseFeatures(result.output)
        }
        let config = codexHome().appendingPathComponent("config.toml")
        let servers = (try? String(contentsOf: config, encoding: .utf8)).map(mcpServerIDs(inConfig:)) ?? []
        return arguments(knownFeatures: features, mcpServers: servers)
    }
}
