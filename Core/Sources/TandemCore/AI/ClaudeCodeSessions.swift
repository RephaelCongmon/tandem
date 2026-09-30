import Foundation
import os

/// One running `claude -p` process in stream-json mode. Its stdin stays open, so the CLI keeps
/// the conversation in memory between questions: a follow-up sends only the new message, and
/// the CLI's prompt cache covers everything before it.
final class ClaudeCodeSession: @unchecked Sendable {
    struct Configuration: Hashable, Sendable {
        /// Paths, not URLs: a directory URL gains a trailing slash once the folder exists, which
        /// would make identical configurations compare unequal.
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
        var workingDirectoryPath: String

        init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
            executablePath = executable.standardizedFileURL.path
            self.arguments = arguments
            self.environment = environment
            workingDirectoryPath = workingDirectory.standardizedFileURL.path
        }
    }

    let configuration: Configuration
    let child: ChildProcess
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    /// Messages the CLI already holds, in order (the thread's message IDs).
    var history: [UUID] = []
    var lastUsed = Date()
    let startedAt = Date()

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
        lines = child.outputLines.makeAsyncIterator()
        try child.start()
    }

    var isAlive: Bool { child.isRunning }

    /// Sends one stream-json line; stdin stays open.
    func send(_ line: Data) throws {
        try child.writeLine(line)
    }

    /// The next line of output, or `nil` once the CLI has exited.
    func nextLine() async throws -> String? {
        try await lines.next()
    }

    func terminate() {
        child.closeInput()
        child.terminate()
    }
}

/// Keeps Claude Code running between questions: the live session of the thread being asked
/// about, and one spare process started ahead of time so the next new conversation doesn't wait
/// for the CLI to launch. An idle process uses about 200 MB, so there's at most one of each, and
/// they're stopped after a while unused.
public final class ClaudeCodeSessionPool: @unchecked Sendable {
    public static let shared = ClaudeCodeSessionPool()

    private let lock = NSLock()
    private var live: (conversationID: UUID, session: ClaudeCodeSession)?
    private var spare: ClaudeCodeSession?
    private var sweeper: DispatchSourceTimer?
    private let log = Logger(subsystem: "com.rofel.tandem", category: "ClaudeCode")

    /// A live conversation is dropped after this long without a question.
    var sessionIdleLimit: TimeInterval = 20 * 60
    /// A spare is replaced after this long, so it never goes stale (sign-in, updates).
    var spareLifetime: TimeInterval = 10 * 60

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

    /// The live session for `conversationID` if it holds exactly `history` with `configuration`;
    /// it's taken out of the pool until checked back in.
    func checkout(conversationID: UUID, configuration: ClaudeCodeSession.Configuration, history: [UUID]) -> ClaudeCodeSession? {
        lock.withLock {
            guard let current = live, current.conversationID == conversationID else { return nil }
            live = nil
            guard current.session.configuration == configuration, current.session.history == history, current.session.isAlive else {
                current.session.terminate()
                return nil
            }
            return current.session
        }
    }

    /// A newly started process: the spare when it matches, otherwise a new one.
    func fresh(configuration: ClaudeCodeSession.Configuration) throws -> ClaudeCodeSession {
        let reusable: ClaudeCodeSession? = lock.withLock {
            defer { spare = nil }
            guard let spare, spare.configuration == configuration, spare.isAlive else {
                spare?.terminate()
                return nil
            }
            return spare
        }
        if let reusable { return reusable }
        return try ClaudeCodeSession(configuration: configuration)
    }

    /// Returns a session that answered successfully, now holding `history`. It replaces any other
    /// live conversation.
    func checkin(_ session: ClaudeCodeSession, conversationID: UUID, history: [UUID]) {
        session.history = history
        session.lastUsed = Date()
        let replaced: ClaudeCodeSession? = lock.withLock {
            let previous = live?.session
            live = (conversationID, session)
            return previous === session ? nil : previous
        }
        replaced?.terminate()
    }

    /// Starts a spare process for `configuration` unless one is ready.
    func prewarm(configuration: ClaudeCodeSession.Configuration) {
        let stale: ClaudeCodeSession? = lock.withLock {
            if let spare, spare.configuration == configuration, spare.isAlive { return nil }
            let old = spare
            spare = nil
            return old
        }
        stale?.terminate()
        do {
            let session = try ClaudeCodeSession(configuration: configuration)
            let extra: ClaudeCodeSession? = lock.withLock {
                if spare == nil {
                    spare = session
                    return nil
                }
                return session
            }
            extra?.terminate()
        } catch {
            log.error("Couldn't start a spare Claude Code: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets a conversation (e.g. its thread was deleted).
    public func end(conversationID: UUID) {
        let ended: ClaudeCodeSession? = lock.withLock {
            guard let current = live, current.conversationID == conversationID else { return nil }
            live = nil
            return current.session
        }
        ended?.terminate()
    }

    /// Stops every process (app quit, provider changed).
    public func removeAll() {
        let all: [ClaudeCodeSession] = lock.withLock {
            defer {
                live = nil
                spare = nil
            }
            return [live?.session, spare].compactMap { $0 }
        }
        for session in all { session.terminate() }
    }

    var hasSpare: Bool { lock.withLock { spare?.isAlive ?? false } }
    var liveConversationID: UUID? { lock.withLock { live?.conversationID } }

    private func sweep() {
        let now = Date()
        let expired: [ClaudeCodeSession] = lock.withLock {
            var gone: [ClaudeCodeSession] = []
            if let current = live, now.timeIntervalSince(current.session.lastUsed) > sessionIdleLimit || !current.session.isAlive {
                gone.append(current.session)
                live = nil
            }
            if let spare, now.timeIntervalSince(spare.startedAt) > spareLifetime || !spare.isAlive {
                gone.append(spare)
                self.spare = nil
            }
            return gone
        }
        for session in expired { session.terminate() }
    }
}
