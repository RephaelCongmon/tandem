import Foundation

/// Protocol version spoken after the secure handshake. Bump on incompatible changes.
public let tandemProtocolVersion = 1

// MARK: - Roles & capture descriptions

/// What a Mac does in a session.
public enum PeerRole: String, Codable, Sendable, Hashable {
    /// Shares its screen or camera.
    case source
    /// Views the live feed and talks to the AI.
    case studio
}

public enum CaptureKind: String, Codable, Sendable, Hashable, CaseIterable {
    case display
    case window
    case camera

    public var displayName: String {
        switch self {
        case .display: return "Display"
        case .window: return "Window"
        case .camera: return "Camera"
        }
    }

    public var systemImage: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .camera: return "camera"
        }
    }
}

/// Identifies something a Source can capture. `id` is stable for the lifetime of
/// the display/window/device on the Source Mac.
public struct CaptureSourceID: Codable, Sendable, Hashable {
    public var kind: CaptureKind
    public var id: String

    public init(kind: CaptureKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// One entry in the list of things a Source offers for capture.
public struct CaptureSourceDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var source: CaptureSourceID
    public var title: String
    public var subtitle: String?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var id: CaptureSourceID { source }

    public init(source: CaptureSourceID, title: String, subtitle: String? = nil, pixelWidth: Int, pixelHeight: Int) {
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

// MARK: - Control payloads

public struct PeerHello: Codable, Sendable, Hashable {
    /// Features a peer supports beyond protocol v1's basics.
    public enum Capability {
        /// Source: can send its computer audio. Studio: can receive and transcribe it.
        public static let audio = "audio"
        /// Source: installs a newer Tandem sent by its Studio (see `UpdateOffer`).
        public static let peerUpdate = "update"
        /// Source: retains a frozen frame and returns only the selected region.
        public static let regionSnapshots = "regionSnapshots"
    }

    public var role: PeerRole
    public var appVersion: String
    public var protocolVersion: Int
    public var capabilities: [String]

    public init(role: PeerRole, appVersion: String, protocolVersion: Int = tandemProtocolVersion, capabilities: [String] = []) {
        self.role = role
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct SourceStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        /// Capturing and able to stream/snapshot.
        case live
        /// The Source user paused sharing; nothing is captured.
        case paused
        /// Screen Recording / Camera permission is missing on the Source.
        case needsPermission
        /// Capture is starting or restarting.
        case starting
        /// Capture failed; `message` explains.
        case error
    }

    public var state: State
    public var capture: CaptureSourceDescriptor?
    public var message: String?
    /// Whether the Studio may choose what is captured.
    public var allowsRemoteSourceSelection: Bool

    public init(state: State, capture: CaptureSourceDescriptor?, message: String? = nil, allowsRemoteSourceSelection: Bool) {
        self.state = state
        self.capture = capture
        self.message = message
        self.allowsRemoteSourceSelection = allowsRemoteSourceSelection
    }
}

/// Live preview quality the Studio asks for. The Source clamps to its own limits.
public struct StreamQuality: Codable, Sendable, Hashable {
    public var maxDimension: Int
    public var maxFPS: Int
    /// Upper bound; the Source adapts below this to keep latency low.
    public var maxBitrateKbps: Int

    public init(maxDimension: Int, maxFPS: Int, maxBitrateKbps: Int) {
        self.maxDimension = maxDimension
        self.maxFPS = maxFPS
        self.maxBitrateKbps = maxBitrateKbps
    }

    public static let smooth = StreamQuality(maxDimension: 1920, maxFPS: 60, maxBitrateKbps: 16_000)
    public static let balanced = StreamQuality(maxDimension: 1920, maxFPS: 30, maxBitrateKbps: 10_000)
    public static let crisp = StreamQuality(maxDimension: 2880, maxFPS: 30, maxBitrateKbps: 24_000)
    public static let bluetooth = StreamQuality(maxDimension: 800, maxFPS: 5, maxBitrateKbps: 250)
}

public struct StreamRequest: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var quality: StreamQuality

    public init(enabled: Bool, quality: StreamQuality) {
        self.enabled = enabled
        self.quality = quality
    }
}

public enum SnapshotTrigger: String, Codable, Sendable, Hashable {
    /// Studio user pressed Capture.
    case manual
    /// Studio auto-capture timer.
    case interval
    /// Studio hotkey.
    case hotkey
    /// Studio composer sent a message with "attach live snapshot".
    case composer
    /// Source user pushed a snapshot (button or hotkey).
    case sourcePush
}

public struct SnapshotRequest: Codable, Sendable, Hashable {
    public var id: UUID
    public var trigger: SnapshotTrigger
    /// Longest edge of the delivered image in pixels (0 = native).
    public var maxDimension: Int
    /// JPEG quality 0…1.
    public var quality: Double
    /// When set, the Source replies `snapshotUnchanged` instead of sending an image
    /// if the screen differs from the last snapshot it sent by less than this (0…1).
    public var skipIfUnchangedBelow: Double?
    /// Prepare a small preview while retaining the native frame on the Source.
    public var prepareRegionSelection: Bool?
    /// Crop this region from the retained frame, never from a newer screen.
    public var region: SnapshotRegion?
    public var frozenSnapshotID: UUID?

    public init(id: UUID = UUID(), trigger: SnapshotTrigger, maxDimension: Int, quality: Double, skipIfUnchangedBelow: Double? = nil, prepareRegionSelection: Bool? = nil, region: SnapshotRegion? = nil, frozenSnapshotID: UUID? = nil) {
        self.id = id
        self.trigger = trigger
        self.maxDimension = maxDimension
        self.quality = quality
        self.skipIfUnchangedBelow = skipIfUnchangedBelow
        self.prepareRegionSelection = prepareRegionSelection
        self.region = region
        self.frozenSnapshotID = frozenSnapshotID
    }
}

/// Precedes the binary chunks of one snapshot.
public struct SnapshotHeader: Codable, Sendable, Hashable {
    public var id: UUID
    public var trigger: SnapshotTrigger
    /// Optional context typed by the Source user when pushing.
    public var note: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var byteCount: Int
    public var chunkCount: Int
    public var mimeType: String
    public var capturedAt: Date
    public var captureTitle: String?

    public init(id: UUID, trigger: SnapshotTrigger, note: String?, pixelWidth: Int, pixelHeight: Int, byteCount: Int, chunkCount: Int, mimeType: String, capturedAt: Date, captureTitle: String?) {
        self.id = id
        self.trigger = trigger
        self.note = note
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.chunkCount = chunkCount
        self.mimeType = mimeType
        self.capturedAt = capturedAt
        self.captureTitle = captureTitle
    }
}

/// The Studio's automation settings, mirrored to the Source for transparency.
public struct AutomationStatus: Codable, Sendable, Hashable {
    public var autoCaptureEnabled: Bool
    public var intervalSeconds: Double
    public var asksAutomatically: Bool

    public init(autoCaptureEnabled: Bool, intervalSeconds: Double, asksAutomatically: Bool) {
        self.autoCaptureEnabled = autoCaptureEnabled
        self.intervalSeconds = intervalSeconds
        self.asksAutomatically = asksAutomatically
    }
}

/// An AI reply mirrored back to the Source Mac (optional feature).
public struct ReplyMirror: Codable, Sendable, Hashable {
    public var threadID: UUID
    public var messageID: UUID
    public var prompt: String?
    public var text: String
    public var isFinal: Bool
    public var model: String?

    public init(threadID: UUID, messageID: UUID, prompt: String?, text: String, isFinal: Bool, model: String?) {
        self.threadID = threadID
        self.messageID = messageID
        self.prompt = prompt
        self.text = text
        self.isFinal = isFinal
        self.model = model
    }
}

public struct PingPayload: Codable, Sendable, Hashable {
    public var id: UInt32
    /// Sender wall clock at send, nanoseconds since 1970.
    public var sentAt: UInt64
    public init(id: UInt32, sentAt: UInt64) {
        self.id = id
        self.sentAt = sentAt
    }
}

public struct PongPayload: Codable, Sendable, Hashable {
    public var id: UInt32
    /// Echo of the ping's `sentAt`.
    public var pingSentAt: UInt64
    /// Responder wall clock when the ping arrived.
    public var receivedAt: UInt64
    /// Responder wall clock when the pong was sent.
    public var sentAt: UInt64
    public init(id: UInt32, pingSentAt: UInt64, receivedAt: UInt64, sentAt: UInt64) {
        self.id = id
        self.pingSentAt = pingSentAt
        self.receivedAt = receivedAt
        self.sentAt = sentAt
    }
}

/// Acknowledges live video frames so the Source can bound end-to-end latency.
public struct VideoAck: Codable, Sendable, Hashable {
    public var sequence: UInt32
    public init(sequence: UInt32) { self.sequence = sequence }
}

// MARK: - Audio

/// How live audio is compressed on the wire.
public enum LiveAudioCodec: String, Codable, Sendable, Hashable, CaseIterable {
    /// Opus in 20 ms frames: about 32 kbps for speech, fine even over Bluetooth.
    case opus
    /// Uncompressed 16-bit little-endian PCM (the fallback when Opus isn't available).
    case pcm16

    var wireValue: UInt8 {
        switch self {
        case .opus: return 1
        case .pcm16: return 2
        }
    }

    init?(wireValue: UInt8) {
        switch wireValue {
        case 1: self = .opus
        case 2: self = .pcm16
        default: return nil
        }
    }
}

/// The Studio asks the Source to start or stop sending its computer audio (for transcripts).
public struct AudioRequest: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Codecs the Studio can decode, most preferred first.
    public var codecs: [LiveAudioCodec]

    public init(enabled: Bool, codecs: [LiveAudioCodec] = LiveAudioCodec.allCases) {
        self.enabled = enabled
        self.codecs = codecs
    }
}

/// Whether the Source is sending audio, and why not.
public struct AudioStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        /// Not requested.
        case off
        case starting
        case live
        /// Sharing is paused or the Source is locked; nothing is captured.
        case paused
        /// Screen & System Audio Recording permission is missing on the Source.
        case needsPermission
        /// The Source's user turned audio sharing off.
        case notAllowed
        case error
    }

    public var state: State
    public var message: String?
    public var codec: LiveAudioCodec?
    public var sampleRate: Int?

    public init(state: State, message: String? = nil, codec: LiveAudioCodec? = nil, sampleRate: Int? = nil) {
        self.state = state
        self.message = message
        self.codec = codec
        self.sampleRate = sampleRate
    }
}

// MARK: - Updates between the Macs

/// The Studio offers the Source its own, newer copy of Tandem (a zip of the signed app), so the
/// Source never needs its own access to the release feed.
public struct UpdateOffer: Codable, Sendable, Hashable {
    public var id: UUID
    public var version: String
    public var build: String
    public var byteCount: Int
    /// Lowercase hex SHA-256 of the zip.
    public var sha256: String

    public init(id: UUID = UUID(), version: String, build: String, byteCount: Int, sha256: String) {
        self.id = id
        self.version = version
        self.build = build
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct UpdateReply: Codable, Sendable, Hashable {
    public var id: UUID
    public var accepted: Bool
    /// Why an offer was declined.
    public var reason: String?

    public init(id: UUID, accepted: Bool, reason: String? = nil) {
        self.id = id
        self.accepted = accepted
        self.reason = reason
    }
}

/// How the Source is getting on with an update the Studio sent.
public struct UpdateTransferStatus: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable, Hashable {
        case receiving
        case verifying
        case installing
        /// Installed; the Source quits and reopens in a moment.
        case restarting
        case failed
    }

    public var id: UUID
    public var phase: Phase
    public var fraction: Double?
    public var message: String?

    public init(id: UUID, phase: Phase, fraction: Double? = nil, message: String? = nil) {
        self.id = id
        self.phase = phase
        self.fraction = fraction
        self.message = message
    }
}

/// Every JSON control message exchanged over an established session.
public enum ControlMessage: Codable, Sendable, Hashable {
    case hello(PeerHello)
    case sourceStatus(SourceStatus)
    case streamRequest(StreamRequest)
    case keyframeRequest
    case videoAck(VideoAck)
    case snapshotRequest(SnapshotRequest)
    /// Releases the native frame when the Studio cancels region selection.
    case discardRegionSelection(id: UUID)
    case snapshotHeader(SnapshotHeader)
    case snapshotUnchanged(id: UUID)
    case snapshotFailed(id: UUID, reason: String)
    case sourceCatalogRequest
    case sourceCatalog([CaptureSourceDescriptor])
    case selectSource(CaptureSourceID)
    case automationStatus(AutomationStatus)
    case replyMirror(ReplyMirror)
    case audioRequest(AudioRequest)
    case audioStatus(AudioStatus)
    case updateOffer(UpdateOffer)
    case updateReply(UpdateReply)
    case updateStatus(UpdateTransferStatus)
    case ping(PingPayload)
    case pong(PongPayload)
    case goodbye(reason: String)
    /// The sender's user ended the session deliberately; the receiver shouldn't reconnect.
    case dismissed(reason: String)
}

// MARK: - Binary payloads

public enum VideoCodec: UInt8, Sendable, Hashable {
    case h264 = 1
    case hevc = 2
}

/// Decoder configuration, sent before the first frame and whenever it changes.
public struct VideoFormat: Sendable, Hashable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    /// SPS/PPS (H.264) or VPS/SPS/PPS (HEVC), without start codes.
    public var parameterSets: [Data]

    public init(codec: VideoCodec, width: Int, height: Int, parameterSets: [Data]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
    }
}

public struct VideoFrame: Sendable, Hashable {
    public var sequence: UInt32
    public var isKeyframe: Bool
    /// Presentation timestamp in microseconds (monotonic on the Source).
    public var presentationMicros: UInt64
    /// Source wall clock at capture, nanoseconds since 1970 (for latency display).
    public var capturedAtNanos: UInt64
    /// AVCC-formatted access unit (4-byte big-endian NAL lengths).
    public var data: Data

    public init(sequence: UInt32, isKeyframe: Bool, presentationMicros: UInt64, capturedAtNanos: UInt64, data: Data) {
        self.sequence = sequence
        self.isKeyframe = isKeyframe
        self.presentationMicros = presentationMicros
        self.capturedAtNanos = capturedAtNanos
        self.data = data
    }
}

public struct SnapshotChunk: Sendable, Hashable {
    public var snapshotID: UUID
    public var index: Int
    public var count: Int
    public var data: Data

    public init(snapshotID: UUID, index: Int, count: Int, data: Data) {
        self.snapshotID = snapshotID
        self.index = index
        self.count = count
        self.data = data
    }
}

/// About 100 ms of the Source's computer audio, mono.
public struct AudioPacket: Sendable, Hashable {
    public var codec: LiveAudioCodec
    public var sequence: UInt32
    public var sampleRate: Int
    /// Samples the packet decodes to.
    public var sampleCount: Int
    /// Source wall clock at the first sample, nanoseconds since 1970.
    public var capturedAtNanos: UInt64
    /// Encoded frames in order: 20 ms Opus frames, or one chunk of PCM.
    public var frames: [Data]

    public init(codec: LiveAudioCodec, sequence: UInt32, sampleRate: Int, sampleCount: Int, capturedAtNanos: UInt64, frames: [Data]) {
        self.codec = codec
        self.sequence = sequence
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.capturedAtNanos = capturedAtNanos
        self.frames = frames
    }
}

/// One piece of an update package.
public struct UpdateChunk: Sendable, Hashable {
    public var offerID: UUID
    public var index: Int
    public var count: Int
    public var data: Data

    public init(offerID: UUID, index: Int, count: Int, data: Data) {
        self.offerID = offerID
        self.index = index
        self.count = count
        self.data = data
    }
}

// MARK: - Envelope

/// Everything that travels inside an established secure session.
public enum PeerMessage: Sendable, Hashable {
    case control(ControlMessage)
    case videoFormat(VideoFormat)
    case videoFrame(VideoFrame)
    case snapshotChunk(SnapshotChunk)
    case audioPacket(AudioPacket)
    case updateChunk(UpdateChunk)
}

public enum PeerMessageCodingError: Error, Equatable {
    case unknownType(UInt8)
    case malformed(String)
}

public enum PeerMessageCodec {
    private enum Tag: UInt8 {
        case control = 1
        case videoFormat = 2
        case videoFrame = 3
        case snapshotChunk = 4
        case audioPacket = 5
        case updateChunk = 6
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    public static func encode(_ message: PeerMessage) throws -> Data {
        switch message {
        case .control(let control):
            var writer = ByteWriter(capacity: 128)
            writer.write(Tag.control.rawValue)
            writer.write(raw: try encoder.encode(control))
            return writer.data

        case .videoFormat(let format):
            var writer = ByteWriter(capacity: 64)
            writer.write(Tag.videoFormat.rawValue)
            writer.write(format.codec.rawValue)
            writer.write(UInt16(clamping: format.width))
            writer.write(UInt16(clamping: format.height))
            writer.write(UInt8(clamping: format.parameterSets.count))
            for set in format.parameterSets.prefix(Int(UInt8.max)) {
                writer.writeShortBlob(set)
            }
            return writer.data

        case .videoFrame(let frame):
            var writer = ByteWriter(capacity: frame.data.count + 32)
            writer.write(Tag.videoFrame.rawValue)
            writer.write(frame.isKeyframe ? UInt8(1) : UInt8(0))
            writer.write(frame.sequence)
            writer.write(frame.presentationMicros)
            writer.write(frame.capturedAtNanos)
            writer.write(raw: frame.data)
            return writer.data

        case .snapshotChunk(let chunk):
            var writer = ByteWriter(capacity: chunk.data.count + 32)
            writer.write(Tag.snapshotChunk.rawValue)
            writer.write(chunk.snapshotID)
            writer.write(UInt32(clamping: chunk.index))
            writer.write(UInt32(clamping: chunk.count))
            writer.write(raw: chunk.data)
            return writer.data

        case .audioPacket(let packet):
            var writer = ByteWriter(capacity: packet.frames.reduce(32) { $0 + $1.count + 2 })
            writer.write(Tag.audioPacket.rawValue)
            writer.write(packet.codec.wireValue)
            writer.write(packet.sequence)
            writer.write(UInt32(clamping: packet.sampleRate))
            writer.write(UInt32(clamping: packet.sampleCount))
            writer.write(packet.capturedAtNanos)
            let frames = packet.frames.prefix(Int(UInt8.max))
            writer.write(UInt8(frames.count))
            for frame in frames {
                guard frame.count <= Int(UInt16.max) else { throw PeerMessageCodingError.malformed("audio frame too large") }
                writer.writeShortBlob(frame)
            }
            return writer.data

        case .updateChunk(let chunk):
            var writer = ByteWriter(capacity: chunk.data.count + 32)
            writer.write(Tag.updateChunk.rawValue)
            writer.write(chunk.offerID)
            writer.write(UInt32(clamping: chunk.index))
            writer.write(UInt32(clamping: chunk.count))
            writer.write(raw: chunk.data)
            return writer.data
        }
    }

    public static func decode(_ data: Data) throws -> PeerMessage {
        var reader = ByteReader(data)
        do {
            let rawTag = try reader.readUInt8()
            guard let tag = Tag(rawValue: rawTag) else { throw PeerMessageCodingError.unknownType(rawTag) }
            switch tag {
            case .control:
                let json = reader.readRemaining()
                do {
                    return .control(try decoder.decode(ControlMessage.self, from: json))
                } catch {
                    throw PeerMessageCodingError.malformed("control: \(error)")
                }

            case .videoFormat:
                guard let codec = VideoCodec(rawValue: try reader.readUInt8()) else {
                    throw PeerMessageCodingError.malformed("unknown codec")
                }
                let width = Int(try reader.readUInt16())
                let height = Int(try reader.readUInt16())
                let count = Int(try reader.readUInt8())
                var sets: [Data] = []
                sets.reserveCapacity(count)
                for _ in 0..<count { sets.append(try reader.readShortBlob()) }
                return .videoFormat(VideoFormat(codec: codec, width: width, height: height, parameterSets: sets))

            case .videoFrame:
                let flags = try reader.readUInt8()
                let sequence = try reader.readUInt32()
                let pts = try reader.readUInt64()
                let captured = try reader.readUInt64()
                return .videoFrame(VideoFrame(
                    sequence: sequence,
                    isKeyframe: flags & 1 == 1,
                    presentationMicros: pts,
                    capturedAtNanos: captured,
                    data: reader.readRemaining()
                ))

            case .snapshotChunk:
                let id = try reader.readUUID()
                let index = Int(try reader.readUInt32())
                let count = Int(try reader.readUInt32())
                guard count > 0, index < count else { throw PeerMessageCodingError.malformed("chunk index") }
                return .snapshotChunk(SnapshotChunk(snapshotID: id, index: index, count: count, data: reader.readRemaining()))

            case .audioPacket:
                guard let codec = LiveAudioCodec(wireValue: try reader.readUInt8()) else {
                    throw PeerMessageCodingError.malformed("unknown audio codec")
                }
                let sequence = try reader.readUInt32()
                let sampleRate = Int(try reader.readUInt32())
                let sampleCount = Int(try reader.readUInt32())
                let captured = try reader.readUInt64()
                let count = Int(try reader.readUInt8())
                var frames: [Data] = []
                frames.reserveCapacity(count)
                for _ in 0..<count { frames.append(try reader.readShortBlob()) }
                guard (8_000...48_000).contains(sampleRate), sampleCount <= sampleRate * 2 else {
                    throw PeerMessageCodingError.malformed("audio format")
                }
                return .audioPacket(AudioPacket(codec: codec, sequence: sequence, sampleRate: sampleRate, sampleCount: sampleCount, capturedAtNanos: captured, frames: frames))

            case .updateChunk:
                let id = try reader.readUUID()
                let index = Int(try reader.readUInt32())
                let count = Int(try reader.readUInt32())
                guard count > 0, index < count else { throw PeerMessageCodingError.malformed("update chunk index") }
                return .updateChunk(UpdateChunk(offerID: id, index: index, count: count, data: reader.readRemaining()))
            }
        } catch is ByteReader.ReadError {
            throw PeerMessageCodingError.malformed("truncated")
        }
    }
}
