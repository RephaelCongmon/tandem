import CoreMedia
import Foundation

public enum VideoSampleError: Error, Equatable {
    case invalidParameterSets(OSStatus)
    case noFormat
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
}

/// Turns received `VideoFormat` + `VideoFrame` messages back into `CMSampleBuffer`s
/// that `AVSampleBufferDisplayLayer` (or VideoToolbox) can decode directly.
public final class VideoSampleBufferFactory {
    public private(set) var formatDescription: CMVideoFormatDescription?
    public private(set) var currentFormat: VideoFormat?

    public init() {}

    /// Installs a new decoder configuration. Returns `true` if it changed.
    @discardableResult
    public func update(format: VideoFormat) throws -> Bool {
        guard format != currentFormat else { return false }
        let description = try Self.makeFormatDescription(format)
        formatDescription = description
        currentFormat = format
        return true
    }

    public func reset() {
        formatDescription = nil
        currentFormat = nil
    }

    /// Wraps a frame. When `displayImmediately` is set the display layer shows it
    /// as soon as it's decoded instead of scheduling against a timebase.
    public func makeSampleBuffer(for frame: VideoFrame, displayImmediately: Bool = true) throws -> CMSampleBuffer {
        guard let formatDescription else { throw VideoSampleError.noFormat }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw VideoSampleError.blockBuffer(status) }
        status = frame.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: frame.data.count)
        }
        guard status == kCMBlockBufferNoErr else { throw VideoSampleError.blockBuffer(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.presentationMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw VideoSampleError.sampleBuffer(status) }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if displayImmediately {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
            if !frame.isKeyframe {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sampleBuffer
    }

    static func makeFormatDescription(_ format: VideoFormat) throws -> CMVideoFormatDescription {
        guard !format.parameterSets.isEmpty else { throw VideoSampleError.invalidParameterSets(-1) }
        var description: CMVideoFormatDescription?
        let sets = format.parameterSets
        // Keep every buffer pinned while CoreMedia copies them.
        let status: OSStatus = withPinnedPointers(sets) { pointers, sizes in
            switch format.codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw VideoSampleError.invalidParameterSets(status) }
        return description
    }
}

private func withPinnedPointers<R>(_ buffers: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
    let copies: [UnsafeMutablePointer<UInt8>] = buffers.map { data in
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
        data.copyBytes(to: pointer, count: data.count)
        return pointer
    }
    defer { copies.forEach { $0.deallocate() } }
    let pointers = copies.map { UnsafePointer($0) }
    let sizes = buffers.map(\.count)
    return pointers.withUnsafeBufferPointer { pointerBuffer in
        sizes.withUnsafeBufferPointer { sizeBuffer in
            body(pointerBuffer.baseAddress!, sizeBuffer.baseAddress!)
        }
    }
}
