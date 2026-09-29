import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import TandemCore

final class MediaTests: XCTestCase {
    private func makePixelBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x * 4] = shade
                    row[x * 4 + 1] = UInt8(truncatingIfNeeded: x)
                    row[x * 4 + 2] = UInt8(truncatingIfNeeded: y)
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testEncodeDecodeRoundTrip() throws {
        let width = 640
        let height = 360
        var frames: [EncodedFrame] = []
        let lock = NSLock()
        let produced = expectation(description: "frames encoded")
        produced.expectedFulfillmentCount = 10

        let encoder = try H264Encoder(width: width, height: height, fps: 30, bitrateKbps: 2000) { frame in
            lock.lock()
            frames.append(frame)
            lock.unlock()
            produced.fulfill()
        }
        for index in 0..<10 {
            let buffer = try XCTUnwrap(makePixelBuffer(width: width, height: height, shade: UInt8(index * 20)))
            try encoder.encode(buffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 30), capturedAtNanos: wallClockNanos(), forceKeyframe: index == 0 || index == 5)
        }
        wait(for: [produced], timeout: 10)
        encoder.invalidate()

        XCTAssertTrue(frames[0].isKeyframe)
        let format = try XCTUnwrap(frames[0].format)
        XCTAssertEqual(format.width, width)
        XCTAssertEqual(format.height, height)
        XCTAssertGreaterThanOrEqual(format.parameterSets.count, 2)
        XCTAssertTrue(frames[5].isKeyframe, "forced keyframe honored")
        XCTAssertFalse(frames[1].isKeyframe)

        // Rebuild sample buffers on the "receiver" and decode them.
        let factory = VideoSampleBufferFactory()
        let wireFormat = try PeerMessageCodec.decode(PeerMessageCodec.encode(.videoFormat(format)))
        guard case .videoFormat(let receivedFormat) = wireFormat else { return XCTFail("format") }
        XCTAssertTrue(try factory.update(format: receivedFormat))
        XCTAssertFalse(try factory.update(format: receivedFormat))

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: try XCTUnwrap(factory.formatDescription),
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        XCTAssertEqual(status, noErr)
        let decoder = try XCTUnwrap(session)
        var decoded = 0
        for (index, encoded) in frames.enumerated() {
            let wire = VideoFrame(sequence: UInt32(index), isKeyframe: encoded.isKeyframe, presentationMicros: UInt64(index) * 33_333, capturedAtNanos: encoded.capturedAtNanos, data: encoded.data)
            let sample = try factory.makeSampleBuffer(for: wire)
            let decodeStatus = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
                if status == noErr, let imageBuffer {
                    XCTAssertEqual(CVPixelBufferGetWidth(imageBuffer), width)
                    decoded += 1
                }
            }
            XCTAssertEqual(decodeStatus, noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        VTDecompressionSessionInvalidate(decoder)
        XCTAssertEqual(decoded, frames.count)
    }

    func testJPEGScalingAndFingerprints() throws {
        let buffer = try XCTUnwrap(makePixelBuffer(width: 1200, height: 800, shade: 40))
        let image = try XCTUnwrap(ImageCodec.cgImage(from: buffer))
        let encoded = try XCTUnwrap(ImageCodec.jpeg(image, quality: 0.85, maxDimension: 600))
        XCTAssertEqual(encoded.width, 600)
        XCTAssertEqual(encoded.height, 400)
        XCTAssertEqual(ImageCodec.pixelSize(of: encoded.data)?.width, 600)

        let thumb = try XCTUnwrap(ImageCodec.thumbnail(encoded.data, maxPixelSize: 120))
        XCTAssertEqual(max(thumb.width, thumb.height), 120)

        let a = try XCTUnwrap(ImageCodec.fingerprint(image))
        let same = try XCTUnwrap(ImageCodec.fingerprint(try XCTUnwrap(ImageCodec.decode(encoded.data))))
        XCTAssertLessThan(a.difference(from: same), 0.02, "re-encoding isn't a change")

        let other = try XCTUnwrap(ImageCodec.cgImage(from: try XCTUnwrap(makePixelBuffer(width: 1200, height: 800, shade: 250))))
        let b = try XCTUnwrap(ImageCodec.fingerprint(other))
        XCTAssertGreaterThan(a.difference(from: b), 0.1)
    }
}
