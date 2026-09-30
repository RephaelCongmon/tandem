import Foundation
import os

public enum CodexServerError: Error, LocalizedError, Sendable, Equatable {
    /// The app server exited or its connection broke.
    case closed(String)
    /// A request came back with a JSON-RPC error.
    case rpc(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .closed(let detail): return detail.isEmpty ? "Codex stopped unexpectedly." : "Codex stopped unexpectedly: \(detail)"
        case .rpc(_, let message): return message
        }
    }
}

/// One running `codex app-server`, spoken to with JSON-RPC over stdio: one JSON object per line.
/// Responses resume their requests; notifications go to listeners (the turns in progress); the
/// server's own requests (approvals and the like) are declined, since Tandem gives Codex no tools.
final class CodexAppServer: @unchecked Sendable {
    struct Configuration: Hashable, Sendable {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
        var workingDirectoryPath: String
    }

    typealias Listener = @Sendable (_ method: String, _ params: [String: Any]) -> Void

    let configuration: Configuration
    private let child: ChildProcess
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var listeners: [UUID: Listener] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Codex")
    var lastUsed = Date()

    init(configuration: Configuration) throws {
        self.configuration = configuration
        let directory = URL(fileURLWithPath: configuration.workingDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        child = ChildProcess(
            executable: URL(fileURLWithPath: configuration.executablePath),
            arguments: configuration.arguments,
            environment: configuration.environment,
            workingDirectory: directory
        )
        let lines = child.outputLines
        try child.start()
        reader = Task { [weak self] in
            do {
                for try await line in lines { self?.handle(line) }
            } catch {}
            self?.connectionEnded()
        }
    }

    var isAlive: Bool { lock.withLock { !closed } && child.isRunning }

    /// Starts the session (`initialize`, then `initialized`).
    func initialize(version: String) async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "tandem", "title": "Tandem", "version": .string(version)]])
        notify("initialized", nil)
    }

    func request(_ method: String, _ params: JSONValue) async throws -> [String: Any] {
        let id: Int = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        return try await withCheckedThrowingContinuation { continuation in
            let failure: Error? = lock.withLock {
                if closed { return CodexServerError.closed(Self.lastLine(child.errorOutput)) }
                pending[id] = continuation
                return nil
            }
            if let failure { return continuation.resume(throwing: failure) }
            send(["id": .int(id), "method": .string(method), "params": params])
        }
    }

    func notify(_ method: String, _ params: JSONValue?) {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        send(.object(message))
    }

    func addListener(_ listener: @escaping Listener) -> UUID {
        let id = UUID()
        lock.withLock { listeners[id] = listener }
        return id
    }

    func removeListener(_ id: UUID) {
        _ = lock.withLock { listeners.removeValue(forKey: id) }
    }

    func terminate() {
        child.closeInput()
        child.terminate()
    }

    var errorOutput: String { child.errorOutput }

    // MARK: Wire

    private func send(_ message: JSONValue) {
        var data = message.serialized()
        data.append(0x0A)
        do {
            try child.writeLine(data)
        } catch {
            connectionEnded()
        }
    }

    private func handle(_ line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        let method = object["method"] as? String
        if let method, let id = object["id"] {
            answerServerRequest(id: id, method: method)
            return
        }
        if let method {
            let params = object["params"] as? [String: Any] ?? [:]
            let current = lock.withLock { Array(listeners.values) }
            for listener in current { listener(method, params) }
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue else { return }
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? -1
            continuation?.resume(throwing: CodexServerError.rpc(code: code, message: error["message"] as? String ?? "Codex couldn't do that."))
        } else {
            continuation?.resume(returning: object["result"] as? [String: Any] ?? [:])
        }
    }

    /// Codex asks the client before running commands, editing files, and so on. Tandem never
    /// allows any of it.
    private func answerServerRequest(id: Any, method: String) {
        let idValue: JSONValue
        if let number = id as? NSNumber { idValue = .int(number.intValue) } else { idValue = .string("\(id)") }
        let result: JSONValue?
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "execCommandApproval", "applyPatchApproval":
            result = ["decision": "denied"]
        case "mcpServer/elicitation/request":
            result = ["action": "decline"]
        default:
            result = nil
        }
        log.info("Declined Codex request \(method, privacy: .public)")
        if let result {
            send(["id": idValue, "result": result])
        } else {
            send(["id": idValue, "error": ["code": -32601, "message": .string("Tandem doesn't support \(method).")]])
        }
    }

    private func connectionEnded() {
        let (waiting, current): ([CheckedContinuation<[String: Any], Error>], [Listener]) = lock.withLock {
            guard !closed else { return ([], []) }
            closed = true
            defer { pending.removeAll() }
            return (Array(pending.values), Array(listeners.values))
        }
        let detail = Self.lastLine(child.errorOutput)
        for continuation in waiting { continuation.resume(throwing: CodexServerError.closed(detail)) }
        // Turns in progress learn the server went away.
        for listener in current { listener("tandem/closed", ["message": detail]) }
    }

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }
}

/// Keeps one Codex app server running between questions, with the live thread of each recent
/// conversation, so a follow-up sends only the new message (Codex remembers the rest and its
/// prompt cache covers it). The server is stopped after a while unused.
public final class CodexSessionPool: @unchecked Sendable {
    public static let shared = CodexSessionPool()

    struct LiveThread {
        var threadID: String
        /// The Tandem messages the thread holds, in order.
        var history: [UUID]
        /// The instructions the thread was started with (they can't change later).
        var instructions: String
        var lastUsed: Date
    }

    private let lock = NSLock()
    private var server: CodexAppServer?
    private var starting: Task<CodexAppServer, Error>?
    private var threads: [UUID: LiveThread] = [:]
    private var sweeper: DispatchSourceTimer?
    /// The server is stopped after this long without a question.
    var idleLimit: TimeInterval = 20 * 60
    var maxThreads = 4

    init() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweeper = timer
    }

    deinit {
        sweeper?.cancel()
    }

    /// A running, initialized server for `configuration`, started if needed.
    func server(for configuration: CodexAppServer.Configuration, clientVersion: String) async throws -> CodexAppServer {
        let (existing, inFlight): (CodexAppServer?, Task<CodexAppServer, Error>?) = lock.withLock {
            if let server, server.configuration == configuration, server.isAlive {
                server.lastUsed = Date()
                return (server, nil)
            }
            return (nil, starting)
        }
        if let existing { return existing }
        if let inFlight, let started = try? await inFlight.value, started.configuration == configuration, started.isAlive { return started }
        let task = Task { () throws -> CodexAppServer in
            let server = try CodexAppServer(configuration: configuration)
            do {
                try await server.initialize(version: clientVersion)
            } catch {
                server.terminate()
                throw error
            }
            return server
        }
        lock.withLock { starting = task }
        let started = try await task.value
        let replaced: CodexAppServer? = lock.withLock {
            let previous = server
            server = started
            starting = nil
            threads.removeAll()
            return previous === started ? nil : previous
        }
        replaced?.terminate()
        return started
    }

    /// The live thread for `conversationID` if it holds exactly `history` with `instructions`.
    func thread(for conversationID: UUID, history: [UUID], instructions: String) -> String? {
        lock.withLock {
            guard let live = threads[conversationID], live.history == history, live.instructions == instructions else {
                threads[conversationID] = nil
                return nil
            }
            return live.threadID
        }
    }

    /// Remembers that `threadID` now holds `history` for `conversationID`.
    func record(_ threadID: String, for conversationID: UUID, history: [UUID], instructions: String) {
        lock.withLock {
            threads[conversationID] = LiveThread(threadID: threadID, history: history, instructions: instructions, lastUsed: Date())
            if threads.count > maxThreads, let oldest = threads.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                threads[oldest] = nil
            }
        }
    }

    /// Forgets a conversation's thread (after a failed or stopped turn).
    public func end(conversationID: UUID) {
        _ = lock.withLock { threads.removeValue(forKey: conversationID) }
    }

    /// Starts Codex ahead of the first question.
    func prewarm(configuration: CodexAppServer.Configuration, clientVersion: String) {
        Task.detached(priority: .utility) { [self] in _ = try? await server(for: configuration, clientVersion: clientVersion) }
    }

    /// Stops Codex (app quit, provider changed).
    public func removeAll() {
        let current: CodexAppServer? = lock.withLock {
            defer {
                server = nil
                threads.removeAll()
            }
            return server
        }
        current?.terminate()
    }

    var isRunning: Bool { lock.withLock { server?.isAlive ?? false } }
    var liveThreadCount: Int { lock.withLock { threads.count } }

    private func sweep() {
        let idle: CodexAppServer? = lock.withLock {
            guard let server, Date().timeIntervalSince(server.lastUsed) > idleLimit || !server.isAlive else { return nil }
            defer {
                self.server = nil
                threads.removeAll()
            }
            return server
        }
        idle?.terminate()
    }
}
