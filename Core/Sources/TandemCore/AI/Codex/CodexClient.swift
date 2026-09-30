import Foundation

/// Answers through the Codex CLI installed on this Mac (`codex app-server`), so questions run on
/// the user's ChatGPT subscription instead of an API key.
///
/// Codex is started with no tools and none of the user's plugins or MCP servers (see
/// ``CodexLaunch``), and each conversation is an ephemeral, read-only thread whose base
/// instructions are Tandem's system prompt. A follow-up in the same thread sends only the new
/// message; a new or changed conversation starts a thread with the history folded into one
/// message, as with Claude Code. Screenshots are passed as local image files.
public struct CodexClient: AIClient {
    public let executable: URL
    let workingDirectory: URL
    let idleTimeout: TimeInterval
    let pool: CodexSessionPool
    /// Launch arguments; `nil` asks the installed Codex which switches it supports.
    let arguments: [String]?

    public init(
        executable: URL,
        workingDirectory: URL = CodexClient.defaultWorkingDirectory,
        idleTimeout: TimeInterval = 300,
        pool: CodexSessionPool = .shared,
        arguments: [String]? = nil
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.idleTimeout = idleTimeout
        self.pool = pool
        self.arguments = arguments
    }

    public static var defaultWorkingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TandemCodex", isDirectory: true)
    }

    static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // MARK: Streaming

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AIEventStream.make { continuation in
            try await run(request, continuation: continuation)
        }
    }

    public func listModels() async throws -> [AIModelInfo] {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AIError.invalidConfiguration(CodexMessages.notFound)
        }
        let server = try await pool.server(for: await configuration(), clientVersion: Self.clientVersion)
        let result = try await server.request("model/list", ["includeHidden": false])
        let models = result["data"] as? [[String: Any]] ?? []
        return models.compactMap { model in
            guard let id = model["id"] as? String, model["hidden"] as? Bool != true else { return nil }
            return AIModelInfo(id: id, displayName: model["displayName"] as? String ?? id)
        }
    }

    /// Starts Codex ahead of the next question.
    public func prewarm() {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let pool = self.pool
        Task.detached(priority: .utility) {
            pool.prewarm(configuration: await configuration(), clientVersion: Self.clientVersion)
        }
    }

    func configuration() async -> CodexAppServer.Configuration {
        let arguments: [String]
        if let fixed = self.arguments {
            arguments = fixed
        } else {
            arguments = await CodexLaunchCache.shared.arguments(for: executable)
        }
        return CodexAppServer.Configuration(
            executablePath: executable.standardizedFileURL.path,
            arguments: arguments,
            environment: CodexLaunch.environment(executable: executable),
            workingDirectoryPath: workingDirectory.standardizedFileURL.path
        )
    }

    private func run(_ request: AIRequest, continuation: AIEventStream.Continuation) async throws {
        let model = try request.validatedModel()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AIError.invalidConfiguration(CodexMessages.notFound)
        }
        guard !request.turns.isEmpty else { throw AIError.invalidConfiguration("There's nothing to send yet.") }
        let server: CodexAppServer
        do {
            server = try await pool.server(for: await configuration(), clientVersion: Self.clientVersion)
        } catch {
            throw Self.startupError(error)
        }
        let instructions = request.systemPrompt.isBlank ? "You are a helpful assistant." : request.systemPrompt

        // Continue the conversation's live thread when it holds exactly the earlier messages.
        let key = request.conversation
        var threadID: String?
        if let key, key.messageIDs.count > 1 {
            threadID = pool.thread(for: key.conversationID, history: Array(key.messageIDs.dropLast()), instructions: instructions)
        }
        let continuing = threadID != nil
        if threadID == nil {
            threadID = try await Self.startThread(on: server, model: model, instructions: instructions, workingDirectory: workingDirectory)
        }
        guard let threadID else { throw AIError.malformedStream("Codex didn't start a conversation.") }

        let images = try ImageFiles(in: workingDirectory)
        defer { images.removeAll() }
        let turns = continuing ? [request.turns[request.turns.count - 1]] : request.turns
        let input = try Self.input(for: turns, folded: !continuing, images: images)

        let capabilities = ModelCatalog.capabilities(for: model, provider: .codex)
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input),
            "model": .string(model),
            "summary": request.includeReasoningSummary ? "concise" : "none"
        ]
        if let effort = capabilities.resolvedEffort(request.effort) { params["effort"] = .string(effort.rawValue) }

        let turn = CodexTurn(threadID: threadID, includeReasoning: request.includeReasoningSummary, continuation: continuation)
        let listener = server.addListener { method, params in turn.handle(method, params) }
        defer { server.removeListener(listener) }
        let watchdog = Task { [idleTimeout] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if turn.secondsSinceActivity > idleTimeout {
                    turn.finish(.timedOut)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        let outcome = await withTaskCancellationHandler {
            do {
                let started = try await server.request("turn/start", .object(params))
                if let id = (started["turn"] as? [String: Any])?["id"] as? String { turn.setTurnID(id) }
            } catch {
                turn.finish(.failed(Self.rpcError(error)))
            }
            continuation.yield(.started(model: model))
            return await turn.wait()
        } onCancel: {
            turn.finish(.cancelled)
        }

        switch outcome {
        case .completed(let usage):
            if let key { pool.record(threadID, for: key.conversationID, history: key.messageIDs + [key.replyID], instructions: instructions) }
            continuation.yield(.completed(AICompletion(stopReason: .endTurn, usage: usage, servedModel: model)))
        case .refused(let message):
            if let key { pool.end(conversationID: key.conversationID) }
            continuation.yield(.completed(AICompletion(stopReason: .refusal(category: nil, explanation: message), servedModel: model)))
        case .cancelled:
            Self.interrupt(server, threadID: threadID, turnID: turn.turnID)
            if let key { pool.end(conversationID: key.conversationID) }
            throw AIError.cancelled
        case .timedOut:
            Self.interrupt(server, threadID: threadID, turnID: turn.turnID)
            if let key { pool.end(conversationID: key.conversationID) }
            throw AIError.timeout
        case .failed(let error):
            if let key { pool.end(conversationID: key.conversationID) }
            throw error
        }
    }

    private static func startThread(on server: CodexAppServer, model: String, instructions: String, workingDirectory: URL) async throws -> String {
        let result: [String: Any]
        do {
            result = try await server.request("thread/start", [
                "model": .string(model),
                "cwd": .string(workingDirectory.path),
                "ephemeral": true,
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "baseInstructions": .string(instructions)
            ])
        } catch {
            throw rpcError(error)
        }
        guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
            throw AIError.malformedStream("Codex didn't start a conversation.")
        }
        return id
    }

    private static func interrupt(_ server: CodexAppServer, threadID: String, turnID: String?) {
        guard let turnID else { return }
        Task { _ = try? await server.request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)]) }
    }

    // MARK: Input

    /// Codex input items for `turns`. With `folded`, an earlier conversation becomes a labelled
    /// transcript ending with the new message (a thread can't be handed assistant turns).
    static func input(for turns: [AITurn], folded: Bool, images: ImageFiles) throws -> [JSONValue] {
        func items(_ turn: AITurn) throws -> [JSONValue] {
            try turn.parts.compactMap { part -> JSONValue? in
                switch part {
                case .text(let text):
                    return text.isBlank ? nil : ["type": "text", "text": .string(text)]
                case .image(let image):
                    guard turn.role == .user, !image.data.isEmpty else { return nil }
                    return ["type": "localImage", "path": .string(try images.write(image).path)]
                }
            }
        }
        let meaningful = turns.drop { $0.role == .assistant }
        guard folded, meaningful.count > 1, let latest = meaningful.last else {
            return try meaningful.flatMap(items)
        }
        var content: [JSONValue] = [["type": "text", "text": "The conversation so far. You are the assistant; screenshots appear where they were shared."]]
        for turn in meaningful.dropLast() {
            content.append(["type": "text", "text": .string(turn.role == .assistant ? "Assistant:" : "User:")])
            content += try items(turn)
        }
        content.append(["type": "text", "text": "The user's new message, which you should answer:"])
        content += try items(latest)
        return content
    }

    // MARK: Errors

    static func startupError(_ error: Error) -> AIError {
        if let error = error as? AIError { return error }
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .invalidConfiguration("Codex couldn't start: \(detail)")
    }

    static func rpcError(_ error: Error) -> AIError {
        if let error = error as? AIError { return error }
        if case CodexServerError.rpc(_, let message)? = error as? CodexServerError { return turnError(message: message, info: nil) }
        return .invalidConfiguration((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Maps Codex's `TurnError` (a message and an error code) to what the chat shows.
    static func turnError(message: String, info: Any?) -> AIError {
        let code = (info as? String) ?? (info as? [String: Any])?.keys.first
        let text = message.isEmpty ? "Codex couldn't answer." : message
        switch code {
        case "unauthorized": return .invalidConfiguration(CodexMessages.signedOut)
        case "usageLimitExceeded", "rateLimitExceeded", "sessionBudgetExceeded": return .rateLimited(retryAfter: nil, message: text)
        case "serverOverloaded", "internalServerError", "httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected": return .overloaded(text)
        case "contextWindowExceeded": return .invalidConfiguration("This conversation is too long for the model. Start a new thread.")
        default:
            let lower = text.lowercased()
            if lower.contains("model") && (lower.contains("not supported") || lower.contains("not found") || lower.contains("does not exist") || lower.contains("not available")) {
                return .invalidConfiguration(CodexMessages.modelUnavailable)
            }
            if lower.contains("log in") || lower.contains("login") || lower.contains("not logged") { return .invalidConfiguration(CodexMessages.signedOut) }
            return .invalidConfiguration(text)
        }
    }
}

/// One turn in progress: turns Codex's notifications into stream events and resolves once.
final class CodexTurn: @unchecked Sendable {
    enum Outcome {
        case completed(AIUsage?)
        case refused(String)
        case cancelled
        case timedOut
        case failed(AIError)
    }

    let threadID: String
    let includeReasoning: Bool
    private let continuation: AIEventStream.Continuation
    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var usage: AIUsage?
    private var lastError: AIError?
    private var lastActivity = Date()
    private var hasReasoning = false
    private(set) var turnID: String?

    init(threadID: String, includeReasoning: Bool, continuation: AIEventStream.Continuation) {
        self.threadID = threadID
        self.includeReasoning = includeReasoning
        self.continuation = continuation
    }

    var secondsSinceActivity: TimeInterval { lock.withLock { Date().timeIntervalSince(lastActivity) } }

    func setTurnID(_ id: String) { lock.withLock { turnID = id } }

    func handle(_ method: String, _ params: [String: Any]) {
        if method == "tandem/closed" {
            let detail = params["message"] as? String ?? ""
            finish(.failed(.invalidConfiguration(detail.isEmpty ? "Codex stopped before answering." : "Codex stopped before answering: \(detail)")))
            return
        }
        guard params["threadId"] as? String == threadID else { return }
        lock.withLock { lastActivity = Date() }
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, !delta.isEmpty { continuation.yield(.textDelta(delta)) }
        case "item/reasoning/summaryTextDelta":
            guard includeReasoning, let delta = params["delta"] as? String, !delta.isEmpty else { return }
            lock.withLock { hasReasoning = true }
            continuation.yield(.reasoningDelta(delta))
        case "item/reasoning/summaryPartAdded":
            if includeReasoning, lock.withLock({ hasReasoning }) { continuation.yield(.reasoningDelta("\n\n")) }
        case "thread/tokenUsage/updated":
            guard let last = (params["tokenUsage"] as? [String: Any])?["last"] as? [String: Any] else { return }
            func int(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
            let cached = int("cachedInputTokens")
            let usage = AIUsage(inputTokens: max(0, int("inputTokens") - cached), outputTokens: int("outputTokens"), cacheReadTokens: cached, cacheWriteTokens: int("cacheWriteInputTokens"))
            lock.withLock { self.usage = usage }
        case "error":
            // Codex retries some failures itself; only a final one counts.
            guard params["willRetry"] as? Bool != true, let error = params["error"] as? [String: Any] else { return }
            let mapped = CodexClient.turnError(message: error["message"] as? String ?? "", info: error["codexErrorInfo"])
            lock.withLock { lastError = mapped }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            switch turn["status"] as? String {
            case "completed":
                finish(.completed(lock.withLock { usage }))
            case "interrupted":
                finish(.cancelled)
            default:
                let error = turn["error"] as? [String: Any]
                let info = error?["codexErrorInfo"]
                if let code = info as? String, code == "cyberPolicy" || code == "misalignmentPolicyViolation" {
                    finish(.refused(error?["message"] as? String ?? "Codex declined to answer."))
                } else if let error {
                    finish(.failed(CodexClient.turnError(message: error["message"] as? String ?? "", info: info)))
                } else {
                    finish(.failed(lock.withLock { lastError } ?? .invalidConfiguration("Codex couldn't answer.")))
                }
            }
        default:
            break
        }
    }

    func finish(_ result: Outcome) {
        let waiting: CheckedContinuation<Outcome, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: result)
    }

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let ready: Outcome? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Screenshots for one turn, written where Codex can read them and removed afterwards.
final class ImageFiles: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private var files: [URL] = []

    init(in directory: URL) throws {
        folder = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write(_ image: AIImage) throws -> URL {
        let ext = image.mimeType.contains("png") ? "png" : "jpg"
        let url = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try image.data.write(to: url, options: [.atomic])
        lock.withLock { files.append(url) }
        return url
    }

    func removeAll() {
        let written = lock.withLock { () -> [URL] in
            defer { files.removeAll() }
            return files
        }
        for url in written { try? FileManager.default.removeItem(at: url) }
    }
}

/// `codex app-server` arguments per executable, rechecked every 10 minutes (reading them runs
/// `codex features list`).
actor CodexLaunchCache {
    static let shared = CodexLaunchCache()
    private var cache: [String: (arguments: [String], at: Date)] = [:]

    func arguments(for executable: URL) async -> [String] {
        let key = executable.standardizedFileURL.path
        if let entry = cache[key], Date().timeIntervalSince(entry.at) < 600 { return entry.arguments }
        let arguments = await CodexLaunch.resolveArguments(executable: executable)
        cache[key] = (arguments, Date())
        return arguments
    }
}
