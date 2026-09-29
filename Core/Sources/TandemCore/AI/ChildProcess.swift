import Foundation

/// A child process with piped stdin, stdout and stderr, driven from async code: output arrives
/// as lines, the tail of stderr is kept for error messages, and ``terminate()`` escalates to
/// SIGKILL if the process ignores SIGTERM.
final class ChildProcess: @unchecked Sendable {
    static let errorTailLimit = 8192

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var errorTail = Data()
    private var lastOutput = Date()
    private var timedOut = false
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(executable: URL, arguments: [String], environment: [String: String]? = nil, workingDirectory: URL? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            self?.exited(process.terminationStatus)
        }
    }

    func start() throws {
        // Writing to a process that already quit must fail with EPIPE, not kill the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.errorTail.append(data)
                if self.errorTail.count > Self.errorTailLimit {
                    self.errorTail = Data(self.errorTail.suffix(Self.errorTailLimit))
                }
            }
        }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw AIError.invalidConfiguration("Couldn't start \(process.executableURL?.lastPathComponent ?? "the helper"): \(error.localizedDescription)")
        }
        noteOutput()
    }

    /// Writes `data` to stdin and closes it. Blocks while the pipe is full, so call it off the
    /// main thread; throws if the process has exited.
    func writeInput(_ data: Data) throws {
        let handle = input.fileHandleForWriting
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    var outputLines: AsyncLineSequence<FileHandle.AsyncBytes> {
        output.fileHandleForReading.bytes.lines
    }

    var errorOutput: String {
        lock.withLock { String(decoding: errorTail, as: UTF8.self) }
    }

    func noteOutput() {
        lock.withLock { lastOutput = Date() }
    }

    var secondsSinceOutput: TimeInterval {
        lock.withLock { Date().timeIntervalSince(lastOutput) }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    /// Asks the process to quit, then kills it if it's still running two seconds later.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(self.process.processIdentifier, SIGKILL)
        }
    }

    /// The exit status, once the process has exited.
    func exitStatus() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func exited(_ code: Int32) {
        let pending: [CheckedContinuation<Int32, Never>] = lock.withLock {
            status = code
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: code) }
    }

    /// Runs a short command to completion and returns its exit status and stdout, or `nil` if
    /// it couldn't start or ran past `timeout`.
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async -> (status: Int32, output: String)? {
        let child = ChildProcess(executable: executable, arguments: arguments, environment: environment)
        guard !Task.isCancelled, (try? child.start()) != nil else { return nil }
        child.closeInput()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            child.markTimedOut()
            child.terminate()
        }
        defer { watchdog.cancel() }
        var lines: [String] = []
        do {
            for try await line in child.outputLines { lines.append(line) }
        } catch {
            child.terminate()
        }
        let status = await child.exitStatus()
        // A cancelled or timed-out run says nothing about the command's real answer.
        if child.didTimeOut || Task.isCancelled { return nil }
        return (status, lines.joined(separator: "\n"))
    }
}
