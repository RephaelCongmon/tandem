import Foundation

/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Hashable {
    /// The `event:` field, or `nil` when the event wasn't named (the SSE default type, "message").
    public var event: String?
    /// All `data:` lines of the event joined with `"\n"`.
    public var data: String
    /// The most recent `id:` value seen on the stream, if any.
    public var id: String?
    /// The `retry:` reconnection delay in milliseconds, if this event carried one.
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// Incremental Server-Sent-Events decoder (WHATWG HTML §9.2 semantics).
///
/// Feed it raw body chunks as they arrive; it returns every event completed by that chunk.
/// Handles LF, CRLF and bare CR line endings (including a CRLF split across chunks), multi-line
/// `data:`, `event:`/`id:`/`retry:` fields, `:` comments, a leading BOM, and events or UTF-8
/// sequences split anywhere across chunks (bytes are only decoded once a line is complete).
/// Call ``finish()`` at end of stream to flush a trailing event that lacks its blank line.
public struct SSEDecoder: Sendable {
    /// Default cap on a single event's buffered size.
    public static let defaultMaxEventSize = 8 * 1024 * 1024

    /// Largest number of bytes one event (pending line + data) may buffer before decoding fails.
    public let maxEventSize: Int

    private var lineBuffer: [UInt8] = []
    private var dataBuffer: [UInt8] = []
    private var eventName: String?
    private var lastEventID: String?
    private var retry: Int?
    /// The previous chunk ended with CR, so a leading LF in the next chunk belongs to that line end.
    private var pendingCR = false
    private var atStreamStart = true

    private static let lf = UInt8(ascii: "\n")
    private static let cr = UInt8(ascii: "\r")
    private static let colon = UInt8(ascii: ":")
    private static let space = UInt8(ascii: " ")

    public init(maxEventSize: Int = SSEDecoder.defaultMaxEventSize) {
        self.maxEventSize = max(1, maxEventSize)
    }

    /// Consumes a chunk of the response body and returns the events it completed.
    /// - Throws: ``AIError/malformedStream(_:)`` if a single event grows beyond ``maxEventSize``.
    public mutating func feed(_ chunk: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var index = 0
            if pendingCR, count > 0 {
                pendingCR = false
                if bytes[0] == Self.lf { index = 1 }
            }
            var lineStart = index
            while index < count {
                let byte = bytes[index]
                if byte == Self.lf || byte == Self.cr {
                    lineBuffer.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[lineStart..<index]))
                    try checkSize()
                    if let event = processBufferedLine() { events.append(event) }
                    if byte == Self.cr {
                        if index + 1 < count {
                            if bytes[index + 1] == Self.lf { index += 1 }
                        } else {
                            pendingCR = true
                        }
                    }
                    index += 1
                    lineStart = index
                } else {
                    index += 1
                }
            }
            if lineStart < count {
                lineBuffer.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[lineStart..<count]))
                try checkSize()
            }
        }
        return events
    }

    /// Flushes the end of the stream: a final unterminated line and any event still waiting for its
    /// blank line are processed and dispatched. The decoder is reset afterwards.
    public mutating func finish() throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !lineBuffer.isEmpty, let event = processBufferedLine() {
            events.append(event)
        }
        if let event = dispatch() {
            events.append(event)
        }
        self = SSEDecoder(maxEventSize: maxEventSize)
        return events
    }

    private func checkSize() throws {
        if lineBuffer.count + dataBuffer.count > maxEventSize {
            throw AIError.malformedStream("A streamed event exceeded \(maxEventSize / (1024 * 1024)) MB.")
        }
    }

    /// Interprets `lineBuffer` as one complete line, clearing it (capacity is kept for reuse).
    private mutating func processBufferedLine() -> SSEEvent? {
        var line: [UInt8] = []
        swap(&line, &lineBuffer)
        defer {
            line.removeAll(keepingCapacity: true)
            swap(&line, &lineBuffer)
        }

        var start = 0
        if atStreamStart {
            atStreamStart = false
            if line.count >= 3, line[0] == 0xEF, line[1] == 0xBB, line[2] == 0xBF { start = 3 }
        }
        if start == line.count { return start == 0 ? dispatch() : nil }
        if line[start] == Self.colon { return nil } // comment

        let body = line[start...]
        let field: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let colonIndex = body.firstIndex(of: Self.colon) {
            field = body[..<colonIndex]
            value = body[(colonIndex + 1)...]
            if value.first == Self.space { value = value.dropFirst() }
        } else {
            field = body
            value = []
        }

        switch String(decoding: field, as: UTF8.self) {
        case "data":
            dataBuffer.append(contentsOf: value)
            dataBuffer.append(Self.lf)
        case "event":
            eventName = String(decoding: value, as: UTF8.self)
        case "id":
            if !value.contains(0) { lastEventID = String(decoding: value, as: UTF8.self) }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ (0x30...0x39).contains($0) }) {
                retry = Int(String(decoding: value, as: UTF8.self))
            }
        default:
            break // unknown fields are ignored per spec
        }
        return nil
    }

    /// Dispatches the pending event (if it has data) and resets per-event state.
    private mutating func dispatch() -> SSEEvent? {
        defer {
            dataBuffer.removeAll(keepingCapacity: true)
            eventName = nil
            retry = nil
        }
        guard !dataBuffer.isEmpty else { return nil }
        let data = String(decoding: dataBuffer.dropLast(), as: UTF8.self)
        let name = (eventName?.isEmpty ?? true) ? nil : eventName
        return SSEEvent(event: name, data: data, id: lastEventID, retry: retry)
    }
}
