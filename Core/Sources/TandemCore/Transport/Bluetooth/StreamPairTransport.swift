import CoreBluetooth
import Foundation
import os

/// A `ByteTransport` over an `InputStream`/`OutputStream` pair: the streams of a
/// `CBL2CAPChannel` in production, or `Stream.getBoundStreams` pairs in tests.
///
/// Threading: like every `ByteTransport`, all methods must be called on `queue` and every
/// callback (state changes, received bytes, send completions) is delivered on `queue`.
/// The streams themselves are scheduled on a single shared background thread
/// ("TandemStreamIO") with its own run loop, never on the main run loop.
///
/// Lifecycle:
/// - The transport starts in `.connecting`; call `start()` after installing callbacks.
///   It reports `.ready` once both streams are open.
/// - It reports exactly one terminal state: `.closed` after `close()` or when the remote
///   end closes its stream, `.failed` on a stream error. Pending send completions then fire
///   with an error, and `onStateChange`/`onReceive` are released to break retain cycles.
/// - Sends issued before `start()` are queued and written once the streams open.
/// - Releasing the transport without calling `close()` still tears the streams down.
public final class StreamPairTransport: ByteTransport {
    /// Maximum number of bytes requested from the input stream per `read`.
    static let readChunkBytes = 64 * 1024
    /// Maximum number of bytes offered to the output stream per `write`.
    static let writeChunkBytes = 64 * 1024

    public let queue: DispatchQueue
    public let linkKind: LinkKind
    public let remoteDescription: String
    /// 48 KB: about a quarter second of BLE L2CAP throughput on a good link.
    public let preferredWindowBytes = 48 * 1024

    public var onStateChange: ((TransportState) -> Void)?
    public var onReceive: ((Data) -> Void)?

    /// The most recently reported state. Read on `queue`.
    public private(set) var state: TransportState = .connecting

    /// Module-internal hook for the Bluetooth managers (e.g. to drop an idle GATT
    /// connection). Fires once on `queue` after the terminal state has been reported, or
    /// asynchronously if the transport is released before reaching one.
    var terminationObserver: (() -> Void)?

    private let io: StreamPairIO
    private var hasStarted = false
    private var isCloseRequested = false
    private var hasFinished = false

    /// Wraps an unopened stream pair.
    ///
    /// - Parameters:
    ///   - inputStream: Bytes from the remote end. Must not be opened or scheduled yet.
    ///   - outputStream: Bytes to the remote end. Must not be opened or scheduled yet.
    ///   - queue: Serial queue for all callbacks and method calls.
    ///   - linkKind: The badge to show for this link (`.bluetooth` by default).
    ///   - remoteDescription: Human-readable description of the remote end, for diagnostics.
    ///   - channel: The object that owns the streams (e.g. a `CBL2CAPChannel`, which closes
    ///     when deallocated). Retained until the transport is torn down.
    public init(
        inputStream: InputStream,
        outputStream: OutputStream,
        queue: DispatchQueue,
        linkKind: LinkKind = .bluetooth,
        remoteDescription: String = "Stream pair",
        channel: AnyObject? = nil
    ) {
        self.queue = queue
        self.linkKind = linkKind
        self.remoteDescription = remoteDescription
        self.io = StreamPairIO(
            input: inputStream,
            output: outputStream,
            channel: channel,
            callbackQueue: queue,
            label: remoteDescription)
        io.owner = self
    }

    /// Wraps the streams of an open L2CAP channel, keeping the channel alive for as long as
    /// the transport is. Returns `nil` if the channel has no streams.
    public convenience init?(channel: CBL2CAPChannel, queue: DispatchQueue, remoteDescription: String? = nil) {
        guard let input = channel.inputStream, let output = channel.outputStream else { return nil }
        let description = remoteDescription
            ?? "Bluetooth LE \(channel.peer?.identifier.uuidString ?? "peer") (PSM \(channel.psm))"
        self.init(
            inputStream: input,
            outputStream: output,
            queue: queue,
            linkKind: .bluetooth,
            remoteDescription: description,
            channel: channel)
    }

    deinit {
        let io = self.io
        StreamIOThread.shared.perform { io.shutdown(.released) }
        if !hasFinished, let observer = terminationObserver {
            queue.async { observer() }
        }
    }

    // MARK: - ByteTransport

    /// Schedules the streams on the IO thread and opens them. Idempotent; ignored after
    /// `close()`.
    public func start() {
        BluetoothInternals.assertOnQueue(queue)
        guard !hasStarted, !isCloseRequested, !hasFinished else { return }
        hasStarted = true
        let io = self.io
        StreamIOThread.shared.perform { io.open() }
    }

    /// Queues `data` behind every earlier send. `completion` fires on `queue` exactly once:
    /// with `nil` when the last byte has been written to the output stream, or with a
    /// `TransportError` if the transport closes or fails first (or was already closed).
    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        BluetoothInternals.assertOnQueue(queue)
        if isCloseRequested || hasFinished {
            let error = terminalError
            queue.async { completion(error) }
            return
        }
        let io = self.io
        StreamIOThread.shared.perform { io.enqueue(data, completion: completion) }
    }

    /// Closes both streams and releases the channel. Idempotent and safe to call from any
    /// callback. Reports `.closed` asynchronously (unless a terminal state was already
    /// reported); no `onReceive` is delivered after this call.
    public func close() {
        BluetoothInternals.assertOnQueue(queue)
        guard !isCloseRequested else { return }
        isCloseRequested = true
        let io = self.io
        StreamIOThread.shared.perform { io.shutdown(.localClose) }
        queue.async { self.finish(.closed) }
    }

    // MARK: - Events from the IO thread (delivered on `queue`)

    fileprivate func ioDidBecomeReady() {
        guard !isCloseRequested, !hasFinished, state == .connecting else { return }
        state = .ready
        onStateChange?(.ready)
    }

    fileprivate func ioDidReceive(_ chunks: [Data]) {
        for chunk in chunks {
            guard !isCloseRequested, !hasFinished else { return }
            onReceive?(chunk)
        }
    }

    fileprivate func ioDidTerminate(_ terminalState: TransportState) {
        finish(terminalState)
    }

    // MARK: - Private

    private var terminalError: TransportError {
        if case .failed(let error) = state { return error }
        return .connectionLost("The connection is closed.")
    }

    private func finish(_ terminalState: TransportState) {
        guard !hasFinished else { return }
        hasFinished = true
        let reported: TransportState = isCloseRequested ? .closed : terminalState
        state = reported
        let stateHandler = onStateChange
        let observer = terminationObserver
        onStateChange = nil
        onReceive = nil
        terminationObserver = nil
        stateHandler?(reported)
        observer?()
    }
}

// MARK: - IO-thread side

/// The stream-facing half of a `StreamPairTransport`. All stored state except `owner` is
/// confined to the `StreamIOThread`; `owner` is only read on the callback queue.
private final class StreamPairIO: NSObject, StreamDelegate {
    enum ShutdownReason {
        case localClose
        case released
        case remoteClosed
        case failed(String)
    }

    private struct PendingWrite {
        let data: Data
        var offset: Int
        let completion: (Error?) -> Void
    }

    /// Read on the callback queue only.
    weak var owner: StreamPairTransport?

    private let input: InputStream
    private let output: OutputStream
    private var channel: AnyObject?
    private let callbackQueue: DispatchQueue
    private let label: String

    // IO-thread state.
    private var pending: [PendingWrite] = []
    private var pendingHead = 0
    private var isOpen = false
    private var isInputOpen = false
    private var isOutputOpen = false
    private var didReportReady = false
    private var isShutDown = false
    private var isPumping = false
    private var shutdownError: TransportError = .connectionLost("The connection is closed.")
    private var readBuffer: UnsafeMutablePointer<UInt8>?

    init(input: InputStream, output: OutputStream, channel: AnyObject?, callbackQueue: DispatchQueue, label: String) {
        self.input = input
        self.output = output
        self.channel = channel
        self.callbackQueue = callbackQueue
        self.label = label
        super.init()
    }

    deinit {
        readBuffer?.deallocate()
    }

    func open() {
        guard !isShutDown, !isOpen else { return }
        isOpen = true
        readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: StreamPairTransport.readChunkBytes)
        let runLoop = RunLoop.current
        input.delegate = self
        output.delegate = self
        input.schedule(in: runLoop, forMode: .default)
        output.schedule(in: runLoop, forMode: .default)
        if input.streamStatus == .notOpen { input.open() }
        if output.streamStatus == .notOpen { output.open() }
        // Streams handed over already open won't send `.openCompleted`.
        if Self.isOpenStatus(input.streamStatus) { markOpened(input: true) }
        if Self.isOpenStatus(output.streamStatus) { markOpened(input: false) }
    }

    func enqueue(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard !isShutDown else {
            let error = shutdownError
            callbackQueue.async { completion(error) }
            return
        }
        pending.append(PendingWrite(data: data, offset: 0, completion: completion))
        pumpWrites()
    }

    func shutdown(_ reason: ShutdownReason) {
        guard !isShutDown else { return }
        isShutDown = true

        let terminalState: TransportState
        switch reason {
        case .localClose, .released:
            terminalState = .closed
            shutdownError = .connectionLost("The connection was closed before the data was sent.")
        case .remoteClosed:
            terminalState = .closed
            shutdownError = .connectionLost("The other Mac closed the connection.")
        case .failed(let message):
            terminalState = .failed(.connectionLost(message))
            shutdownError = .connectionLost(message)
        }
        switch reason {
        case .failed(let message):
            BluetoothInternals.logger.error("Stream transport \(self.label, privacy: .public) failed: \(message, privacy: .public)")
        case .remoteClosed:
            BluetoothInternals.logger.info("Stream transport \(self.label, privacy: .public) closed by the remote end")
        case .localClose, .released:
            BluetoothInternals.logger.debug("Stream transport \(self.label, privacy: .public) closed locally")
        }

        input.delegate = nil
        output.delegate = nil
        if isOpen {
            input.remove(from: .current, forMode: .default)
            output.remove(from: .current, forMode: .default)
        }
        input.close()
        output.close()
        channel = nil

        let failed = pending[pendingHead...].map(\.completion)
        pending.removeAll()
        pendingHead = 0
        let error = shutdownError
        callbackQueue.async {
            for completion in failed { completion(error) }
            self.owner?.ioDidTerminate(terminalState)
        }
    }

    // MARK: StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        autoreleasepool {
            guard !isShutDown else { return }
            if aStream === input {
                handleInputEvent(eventCode)
            } else if aStream === output {
                handleOutputEvent(eventCode)
            }
        }
    }

    private func handleInputEvent(_ event: Stream.Event) {
        if event.contains(.openCompleted) { markOpened(input: true) }
        if event.contains(.hasBytesAvailable) {
            markOpened(input: true)
            readAvailableBytes()
        }
        if event.contains(.errorOccurred) {
            shutdown(.failed(Self.describe(input.streamError, fallback: "The input stream failed.")))
            return
        }
        if event.contains(.endEncountered) {
            readAvailableBytes()
            shutdown(.remoteClosed)
        }
    }

    private func handleOutputEvent(_ event: Stream.Event) {
        if event.contains(.openCompleted) { markOpened(input: false) }
        if event.contains(.hasSpaceAvailable) {
            markOpened(input: false)
            pumpWrites()
        }
        if event.contains(.errorOccurred) {
            shutdown(.failed(Self.describe(output.streamError, fallback: "The output stream failed.")))
            return
        }
        if event.contains(.endEncountered) {
            shutdown(.remoteClosed)
        }
    }

    // MARK: Reading

    private func readAvailableBytes() {
        guard !isShutDown, let buffer = readBuffer else { return }
        var chunks: [Data] = []
        var failure: String?
        var reads = 0
        while input.hasBytesAvailable {
            let count = input.read(buffer, maxLength: StreamPairTransport.readChunkBytes)
            if count > 0 {
                chunks.append(Data(bytes: buffer, count: count))
                reads += 1
                if reads >= 16 {
                    // Yield so writes and other transports get a turn; resume right after.
                    StreamIOThread.shared.perform { [self] in readAvailableBytes() }
                    break
                }
            } else if count == 0 {
                break  // End of stream; `.endEncountered` follows.
            } else {
                failure = Self.describe(input.streamError, fallback: "Reading from the stream failed.")
                break
            }
        }
        if !chunks.isEmpty {
            callbackQueue.async { self.owner?.ioDidReceive(chunks) }
        }
        if let failure { shutdown(.failed(failure)) }
    }

    // MARK: Writing

    private func pumpWrites() {
        guard isOpen, !isShutDown, !isPumping else { return }
        isPumping = true
        defer { isPumping = false }

        var finished: [(Error?) -> Void] = []
        var failure: String?
        while pendingHead < pending.count {
            let item = pending[pendingHead]
            if item.offset >= item.data.count {
                finished.append(item.completion)
                pendingHead += 1
                continue
            }
            guard output.hasSpaceAvailable else { break }
            let written = write(item.data, from: item.offset)
            if written < 0 {
                failure = Self.describe(output.streamError, fallback: "Writing to the stream failed.")
                break
            }
            if written == 0 { break }  // Wait for the next `.hasSpaceAvailable`.
            pending[pendingHead].offset += written
        }
        compactPending()

        if !finished.isEmpty {
            callbackQueue.async {
                for completion in finished { completion(nil) }
            }
        }
        if let failure { shutdown(.failed(failure)) }
    }

    private func write(_ data: Data, from offset: Int) -> Int {
        data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            let length = min(raw.count - offset, StreamPairTransport.writeChunkBytes)
            return output.write(base + offset, maxLength: length)
        }
    }

    private func compactPending() {
        if pendingHead == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 64, pendingHead * 2 >= pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    // MARK: Helpers

    private func markOpened(input isInput: Bool) {
        if isInput { isInputOpen = true } else { isOutputOpen = true }
        guard isInputOpen, isOutputOpen, !didReportReady else { return }
        didReportReady = true
        callbackQueue.async { self.owner?.ioDidBecomeReady() }
        pumpWrites()
    }

    private static func isOpenStatus(_ status: Stream.Status) -> Bool {
        switch status {
        case .open, .reading, .writing: return true
        default: return false
        }
    }

    private static func describe(_ error: Error?, fallback: String) -> String {
        error?.localizedDescription ?? fallback
    }
}

// MARK: - Shared IO thread

/// One long-lived background thread whose run loop hosts every transport's streams.
final class StreamIOThread: @unchecked Sendable {
    static let shared = StreamIOThread()

    /// Immutable after init; `CFRunLoopPerformBlock`/`CFRunLoopWakeUp` are thread-safe.
    private let runLoop: CFRunLoop

    private final class Handoff: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var runLoop: CFRunLoop?
    }

    private init() {
        let handoff = Handoff()
        let thread = Thread {
            let runLoop = RunLoop.current
            // A port keeps `run(mode:before:)` blocking instead of returning immediately.
            runLoop.add(NSMachPort(), forMode: .default)
            handoff.runLoop = CFRunLoopGetCurrent()
            handoff.ready.signal()
            while true {
                autoreleasepool {
                    _ = runLoop.run(mode: .default, before: .distantFuture)
                }
            }
        }
        thread.name = "TandemStreamIO"
        thread.qualityOfService = .userInitiated
        thread.start()
        handoff.ready.wait()
        guard let runLoop = handoff.runLoop else {
            preconditionFailure("TandemStreamIO thread failed to publish its run loop")
        }
        self.runLoop = runLoop
    }

    /// Runs `block` on the IO thread, after every previously performed block.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            autoreleasepool { block() }
        }
        CFRunLoopWakeUp(runLoop)
    }
}

// All public state is confined to `queue`; stream IO runs on the shared IO thread.
extension StreamPairTransport: @unchecked Sendable {}
