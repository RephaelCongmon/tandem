import CoreGraphics
import XCTest
@testable import TandemCore

final class RegionSnapshotTests: XCTestCase {
    // MARK: Pixel mapping

    func testRegionMapsToWholePixels() {
        let region = SnapshotRegion(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        XCTAssertEqual(region.pixelRect(width: 1000, height: 800), CGRect(x: 250, y: 400, width: 500, height: 200))
    }

    func testRegionRoundsOutwardAndStaysInsideTheImage() {
        // A third of 1000 px isn't whole: include every partly selected pixel.
        let third = SnapshotRegion(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        XCTAssertEqual(third.pixelRect(width: 1000, height: 10), CGRect(x: 333, y: 0, width: 334, height: 10))
        // Floating-point drift past the edge is clamped, not rejected.
        let edge = SnapshotRegion(x: 0.5, y: 0.5, width: 0.5 + 1e-12, height: 0.5 + 1e-12)
        XCTAssertEqual(edge.pixelRect(width: 100, height: 100), CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    func testInvalidRegionsAreRejectedRatherThanWidened() {
        let invalid = [
            SnapshotRegion(x: -0.1, y: 0, width: 0.5, height: 0.5),
            SnapshotRegion(x: 0, y: 0, width: 0, height: 0.5),
            SnapshotRegion(x: 0.6, y: 0, width: 0.5, height: 0.5),
            SnapshotRegion(x: .nan, y: 0, width: 0.5, height: 0.5),
            SnapshotRegion(x: 0, y: 0, width: .infinity, height: 0.5)
        ]
        for region in invalid {
            XCTAssertNil(region.pixelRect(width: 100, height: 100), "\(region)")
        }
        XCTAssertNil(SnapshotRegion.full.pixelRect(width: 0, height: 100))
    }

    // MARK: Selecting on the stage

    func testAspectFitMatchesTheLetterboxedVideo() {
        let fitted = SnapshotRegion.aspectFit(CGSize(width: 1600, height: 900), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(fitted, CGRect(x: 0, y: 218.75, width: 1000, height: 562.5))
    }

    func testDragOnTheStageBecomesANormalizedRegion() throws {
        let video = CGRect(x: 0, y: 218.75, width: 1000, height: 562.5)
        let drag = CGRect(x: 100, y: 218.75, width: 500, height: 281.25)
        let region = try XCTUnwrap(SnapshotRegion(selection: drag, in: video))
        XCTAssertEqual(region.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(region.y, 0, accuracy: 1e-9)
        XCTAssertEqual(region.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(region.height, 0.5, accuracy: 1e-9)
    }

    func testDragPastTheVideoEdgeIsClampedToTheVideo() throws {
        let video = CGRect(x: 0, y: 100, width: 800, height: 400)
        let region = try XCTUnwrap(SnapshotRegion(selection: CGRect(x: 600, y: 0, width: 400, height: 300), in: video))
        XCTAssertEqual(region.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(region.y, 0, accuracy: 1e-9)
        XCTAssertEqual(region.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(region.height, 0.5, accuracy: 1e-9)
    }

    func testClickOrTinyDragSelectsNothing() {
        let video = CGRect(x: 0, y: 0, width: 800, height: 400)
        XCTAssertNil(SnapshotRegion(selection: CGRect(x: 10, y: 10, width: 3, height: 40), in: video))
        XCTAssertNil(SnapshotRegion(selection: CGRect(x: 900, y: 10, width: 50, height: 50), in: video))
    }

    // MARK: Cropping

    func testCropKeepsExactlyTheSelectedPixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: ImageCodec.srgb,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        let image = try XCTUnwrap(context.makeImage())

        let cropped = try XCTUnwrap(SnapshotRegion(x: 0.5, y: 0, width: 0.5, height: 1).cropped(from: image))
        XCTAssertEqual(cropped.width, 50)
        XCTAssertEqual(cropped.height, 50)
        let pixels = try XCTUnwrap(rgba(cropped))
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(Array(pixels[pixel..<pixel + 3]), [0, 0, 255])
        }
    }

    private func rgba(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: ImageCodec.srgb,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    // MARK: Freezing

    func testDisplayedFrameIsCurrentOnlyWhenNothingNewerWasCaptured() {
        XCTAssertTrue(SnapshotFreeze.displayedFrameIsCurrent(displayed: 1_000, latestCaptured: 1_000))
        XCTAssertFalse(SnapshotFreeze.displayedFrameIsCurrent(displayed: 1_000, latestCaptured: 1_001))
        // No displayed frame, or no stream on the Source: send a preview.
        XCTAssertFalse(SnapshotFreeze.displayedFrameIsCurrent(displayed: nil, latestCaptured: 1_000))
        XCTAssertFalse(SnapshotFreeze.displayedFrameIsCurrent(displayed: 1_000, latestCaptured: nil))
    }

    // MARK: Wire

    func testRegionRequestsRoundTrip() throws {
        let frozen = UUID()
        let messages: [ControlMessage] = [
            .snapshotRequest(SnapshotRequest(trigger: .manual, maxDimension: 1600, quality: 0.8, freeze: SnapshotFreeze(displayedFrameNanos: 42))),
            .snapshotRequest(SnapshotRequest(trigger: .manual, maxDimension: 2576, quality: 0.9,
                                             crop: SnapshotCrop(frozenID: frozen, region: SnapshotRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))),
            .releaseFrozenSnapshot(id: frozen),
            .hello(PeerHello(role: .source, appVersion: "1.6.0", capabilities: [PeerHello.Capability.regionSnapshots]))
        ]
        for message in messages {
            XCTAssertEqual(try PeerMessageCodec.decode(PeerMessageCodec.encode(.control(message))), .control(message))
        }
    }

    func testRequestsFromOlderStudiosStillDecode() throws {
        // What a 1.5 Studio sends: no freeze or crop fields.
        let json = #"{"snapshotRequest":{"_0":{"id":"8D6B4E0C-3F0A-4C57-9B7E-2B1B7B9C2E11","trigger":"manual","maxDimension":2576,"quality":0.9}}}"#
        // Tag 1 = JSON control message.
        let message = try PeerMessageCodec.decode(Data([1]) + Data(json.utf8))
        guard case .control(.snapshotRequest(let request)) = message else { return XCTFail("\(message)") }
        XCTAssertNil(request.freeze)
        XCTAssertNil(request.crop)
    }
}
