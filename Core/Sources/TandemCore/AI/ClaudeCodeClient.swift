import Foundation

/// Answers through the Claude Code command-line tool installed on this Mac, so questions run on
/// the user's Claude subscription instead of an API key.
///
/// Each request starts `claude -p` with a clean slate: no tools, and `--safe-mode` keeps the
/// user's hooks, plugins, MCP servers, skills and CLAUDE.md files out of it, while Tandem's
/// instructions replace Claude Code's own system prompt. The conversation goes to stdin as a
/// single stream-json user message. The CLI can't be handed earlier assistant turns, so prior
/// turns are folded into that message as a labelled transcript with screenshots in place. The
/// CLI relays the Messages API stream events, which ``AnthropicStreamParser`` already reads.
public struct ClaudeCodeClient: AIClient {
    public let executable: URL
    let environment: [String: String]
    let workingDirectory: URL
    /// The CLI is stopped if it prints nothing for this long.
    let idleTimeout: TimeInterval

    /// - Parameters:
    ///   - executable: The `claude` binary (see ``ClaudeCodeLocator``).
    ///   - environment: Base environment for the child; scrubbed by ``childEnvironment(from:executable:maxOutputTokens:)``.
    ///   - workingDirectory: An empty directory to run in, so no project files are picked up.
    public init(
        executable: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = ClaudeCodeClient.defaultWorkingDirectory,
        idleTimeout: TimeInterval = 300
    ) {
        self.executable = executable
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.idleTimeout = idleTimeout
    }

    public static var defaultWorkingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TandemClaudeCode", isDirectory: true)
    }

    // MARK: Streaming

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AIEventStream.make { continuation in
            try await run(request, continuation: continuation)
        }
    }

    private func run(_ request: AIRequest, continuation: AIEventStream.Continuation) async throws {
        let model = try request.validatedModel()
        let input = try Self.inputLine(for: request)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AIError.invalidConfiguration(ClaudeCodeMessages.notFound)
        }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let child = ChildProcess(
            executable: executable,
            arguments: Self.arguments(for: request, model: model),
            environment: Self.childEnvironment(from: environment, executable: executable, maxOutputTokens: request.maxOutputTokens),
            workingDirectory: workingDirectory
        )
        try child.start()

        let watchdog = Task { [idleTimeout] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if child.secondsSinceOutput > idleTimeout {
                    child.markTimedOut()
                    child.terminate()
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            child.terminate()
        }

        var parser = ClaudeCodeStreamParser(includeReasoning: request.includeReasoningSummary)
        try await withTaskCancellationHandler {
            // A failed write (the CLI exited early) surfaces through the output below.
            let writer = Task.detached { try? child.writeInput(input) }
            for try await line in child.outputLines {
                child.noteOutput()
                for event in try parser.consume(line: line) { continuation.yield(event) }
                if parser.isFinished { break }
            }
            _ = await writer.value
            if parser.isFinished { return }
            let status = await child.exitStatus()
            if child.didTimeOut { throw AIError.timeout }
            try Task.checkCancellation()
            for event in try parser.finish(exitStatus: status, errorOutput: child.errorOutput) { continuation.yield(event) }
        } onCancel: {
            child.terminate()
        }
    }

    public func listModels() async throws -> [AIModelInfo] {
        ModelCatalog.presets(for: .claudeCode).map { AIModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    // MARK: Invocation

    static func arguments(for request: AIRequest, model: String) -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages",
            // A clean slate: no tools, and none of the user's hooks, plugins, MCP servers,
            // skills or CLAUDE.md files. Sign-in works as usual.
            "--safe-mode", "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
            "--no-session-persistence",
            "--model", model
        ]
        if let effort = ModelCatalog.anthropicCapabilities(for: model).resolvedEffort(request.effort) {
            arguments += ["--effort", effort.rawValue]
        }
        let system = request.systemPrompt.isBlank ? "You are a helpful assistant." : request.systemPrompt
        arguments += ["--system-prompt", system]
        return arguments
    }

    /// Keys that would make the CLI refuse to start or bill an API key instead of the subscription.
    static let scrubbedEnvironmentKeys = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"
    ]

    static func childEnvironment(from base: [String: String], executable: URL, maxOutputTokens: Int) -> [String: String] {
        var environment = base
        for key in scrubbedEnvironmentKeys { environment[key] = nil }
        environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        environment["DISABLE_AUTOUPDATER"] = "1"
        // Apps get a minimal PATH; the CLI's own directory keeps its helpers reachable.
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + path
        return environment
    }

    /// The stream-json line for `request`: one user message holding the whole conversation.
    static func inputLine(for request: AIRequest) throws -> Data {
        let messages = try AnthropicClient.makeMessages(from: request.turns)
        let line: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": .array(foldedContent(messages))]
        ]
        var data = line.serialized()
        data.append(0x0A)
        return data
    }

    /// Folds Messages API `messages` into the content of one user message. A single user turn is
    /// sent as is; longer conversations become a transcript that ends with the new message.
    static func foldedContent(_ messages: [JSONValue]) -> [JSONValue] {
        let turns: [(role: String, content: [JSONValue])] = messages.compactMap { message in
            guard case .object(let fields) = message,
                  case .string(let role)? = fields["role"],
                  case .array(let content)? = fields["content"] else { return nil }
            return (role, content)
        }
        guard turns.count > 1, let latest = turns.last else { return turns.first?.content ?? [] }
        func label(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
        var content = [label("The conversation so far. You are the assistant; screenshots appear where they were shared.")]
        for turn in turns.dropLast() {
            content.append(label(turn.role == "assistant" ? "Assistant:" : "User:"))
            content.append(contentsOf: turn.content)
        }
        content.append(label("The user's new message, which you should answer:"))
        content.append(contentsOf: latest.content)
        return content
    }
}

// MARK: - Messages

public enum ClaudeCodeMessages {
    public static let notFound = "Claude Code isn't installed on this Mac. Install it from claude.com/claude-code, or set its location in Settings › AI."
    public static let signedOut = "Claude Code isn't signed in. Open Terminal, run `claude`, and sign in with your Claude account."
    public static let modelUnavailable = "Your Claude plan can't use this model through Claude Code. Pick another one in Settings › AI."
}

// MARK: - Output parsing

/// Turns the CLI's stream-json output lines into ``AIStreamEvent``s.
///
/// `stream_event` lines carry raw Messages API events. The CLI reports failures (signed out, an
/// unavailable model, a usage limit) as a synthetic assistant message with an `error` code
/// followed by a `result` line with `is_error`; the completion is held until that `result`.
struct ClaudeCodeStreamParser {
    let includeReasoning: Bool
    private(set) var isFinished = false
    private var messages: AnthropicStreamParser
    private var completion: AICompletion?
    private var errorCode: String?
    /// Set when the CLI reported that the plan's usage limit is reached.
    private var usageLimit: (reached: Bool, resetsAt: Date?) = (false, nil)

    init(includeReasoning: Bool) {
        self.includeReasoning = includeReasoning
        messages = AnthropicStreamParser(includeReasoning: includeReasoning)
    }

    mutating func consume(line: String) throws -> [AIStreamEvent] {
        guard !isFinished,
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  let eventType = event["type"] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: event) else { return [] }
            // The CLI retries failed API calls itself; each attempt starts a fresh message.
            if eventType == "message_start", messages.isFinished {
                messages = AnthropicStreamParser(includeReasoning: includeReasoning)
            }
            var events = try messages.consume(SSEEvent(event: eventType, data: String(decoding: data, as: UTF8.self)))
            events.removeAll { event in
                guard case .completed(let finished) = event else { return false }
                completion = finished
                return true
            }
            return events
        case "assistant":
            if let code = object["error"] as? String { errorCode = code }
            return []
        case "rate_limit_event":
            if let info = object["rate_limit_info"] as? [String: Any], info["status"] as? String == "rejected" {
                usageLimit = (true, (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
            return []
        case "result":
            isFinished = true
            if object["is_error"] as? Bool == true {
                throw Self.error(code: errorCode, message: object["result"] as? String, status: object["api_error_status"] as? Int, usageLimit: usageLimit)
            }
            return [.completed(completion ?? AICompletion(stopReason: .endTurn))]
        default:
            return []
        }
    }

    /// Called when the output ended without a `result` line.
    mutating func finish(exitStatus: Int32, errorOutput: String) throws -> [AIStreamEvent] {
        isFinished = true
        if let completion { return [.completed(completion)] }
        let detail = errorOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        if detail.isEmpty {
            throw AIError.invalidConfiguration("Claude Code stopped before answering (exit code \(exitStatus)).")
        }
        throw AIError.invalidConfiguration("Claude Code stopped before answering: \(detail)")
    }

    static func error(code: String?, message: String?, status: Int?, usageLimit: (reached: Bool, resetsAt: Date?) = (false, nil)) -> AIError {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Claude Code couldn't answer."
        switch code {
        case "authentication_failed":
            return .invalidConfiguration(ClaudeCodeMessages.signedOut)
        case "model_not_found":
            return .invalidConfiguration(ClaudeCodeMessages.modelUnavailable)
        case "rate_limit":
            return .rateLimited(retryAfter: usageLimit.resetsAt.map { max(0, $0.timeIntervalSinceNow) }, message: text)
        case "server_error":
            return .overloaded(text)
        default:
            if usageLimit.reached { return .rateLimited(retryAfter: usageLimit.resetsAt.map { max(0, $0.timeIntervalSinceNow) }, message: text) }
            if status == 529 { return .overloaded(text) }
            return .invalidConfiguration(text)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
