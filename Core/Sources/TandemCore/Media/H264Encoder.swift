import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// One compressed access unit ready to send.
public struct EncodedFrame: @unchecked Sendable {
    public var data: Data
    public var isKeyframe: Bool
    public var presentationTime: CMTime
    /// Present on keyframes (and whenever the configuration changes).
    public var format: VideoFormat?
    /// Source wall-clock capture time, carried through for latency measurement.
    public var capturedAtNanos: UInt64
}

public enum VideoEncoderError: Error, LocalizedError {
    case sessionCreationFailed(OSStatus)
    case encodeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status): return "Couldn't start the video encoder (\(status))."
        case .encodeFailed(let status): return "Video encoding failed (\(status))."
        }
    }
}

/// Hardware H.264 encoder configured for interactive, low-latency screen streaming:
/// low-latency rate control, no frame reordering, no B-frames, on-demand keyframes.
///
/// Thread-safety: `encode` may be called from any single capture queue; the
/// output handler is invoked on VideoToolbox's callback thread.
public final class H264Encoder {
    public let width: Int
    public let height: Int
    public private(set) var bitrateKbps: Int
    public private(set) var fps: Int

    private var session: VTCompressionSession?
    private let output: (EncodedFrame) -> Void
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Encoder")

    /// - Parameter output: receives encoded frames in decode order (= presentation order).
    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int, output: @escaping (EncodedFrame) -> Void) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.output = output

        var encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        encoderSpec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VideoEncoderError.sessionCreationFailed(status) }
        session = created

        func set(_ key: CFString, _ value: Any) {
            let result = VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
            if result != noErr {
                log.debug("Encoder property \(key as String, privacy: .public) unsupported (\(result))")
            }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as Any)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as Any)
        // Low-latency rate control supports the constrained profiles only.
        if VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel) != noErr {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        }
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue as Any)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        // Keyframes are requested on demand (new viewer / recovery); keep a long GOP.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 10)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        applyBitrate(bitrateKbps, to: created)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit {
        invalidate()
    }

    public func invalidate() {
        lock.lock()
        let current = session
        session = nil
        lock.unlock()
        if let current {
            VTCompressionSessionCompleteFrames(current, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(current)
        }
    }

    /// Adjusts the target bitrate without restarting the session.
    public func setBitrate(kbps: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, kbps != bitrateKbps else { return }
        bitrateKbps = kbps
        applyBitrate(kbps, to: session)
    }

    public func setFrameRate(_ newFPS: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, newFPS != fps else { return }
        fps = newFPS
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: newFPS as CFNumber)
    }

    private func applyBitrate(_ kbps: Int, to session: VTCompressionSession) {
        let bitsPerSecond = kbps * 1000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
        // Hard cap over 1s windows at 1.5× the average, which bounds burst size.
        let bytesPerWindow = Double(bitsPerSecond) * 1.5 / 8
        let limits = [bytesPerWindow, 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// Encodes one frame. `forceKeyframe` produces an IDR with parameter sets.
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, capturedAtNanos: UInt64, forceKeyframe: Bool) throws {
        lock.lock()
        let current = session
        lock.unlock()
        guard let current else { return }

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            current,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer else {
                if status != noErr { self.log.error("Encode callback error \(status)") }
                return
            }
            self.handle(sampleBuffer, capturedAtNanos: capturedAtNanos)
        }
        if status != noErr { throw VideoEncoderError.encodeFailed(status) }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer, capturedAtNanos: UInt64) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var format: VideoFormat?
        if isKeyframe, let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let sets = Self.parameterSets(from: description)
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let candidate = VideoFormat(codec: .h264, width: Int(dimensions.width), height: Int(dimensions.height), parameterSets: sets)
            format = candidate
        }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let data: Data
        if CMBlockBufferIsRangeContiguous(dataBuffer, atOffset: 0, length: length) {
            data = Data(bytes: pointer, count: length)
        } else {
            var copy = Data(count: length)
            let ok = copy.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base) == noErr
            }
            guard ok else { return }
            data = copy
        }

        output(EncodedFrame(
            data: data,
            isKeyframe: isKeyframe,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            format: format,
            capturedAtNanos: capturedAtNanos
        ))
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    static func parameterSets(from description: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return [] }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}
