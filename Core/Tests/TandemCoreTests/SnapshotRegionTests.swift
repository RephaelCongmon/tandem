import CoreGraphics
import XCTest
@testable import TandemCore

final class SnapshotRegionTests: XCTestCase {
    func testCropCoordinatesUseNativePixelsAndRoundOutwards() {
        let region = SnapshotRegion(x: 0.251, y: 0.126, width: 0.5, height: 0.25)
        XCTAssertEqual(region.pixelRect(width: 100, height: 80), CGRect(x: 25, y: 10, width: 51, height: 21))
    }

    func testInvalidRegionsNeverReturnTheFullScreen() {
        for region in [
            SnapshotRegion(x: -.infinity, y: 0, width: 1, height: 1),
            SnapshotRegion(x: 0, y: .nan, width: 1, height: 1),
            SnapshotRegion(x: -0.1, y: 0, width: 0.5, height: 1),
            SnapshotRegion(x: 0, y: 0, width: 0, height: 1),
            SnapshotRegion(x: 0.9, y: 0, width: 0.2, height: 1)
        ] {
            XCTAssertNil(region.pixelRect(width: 100, height: 80))
        }
    }

    func testDragIgnoresLetterboxingAndClampsToTheImage() {
        let imageRect = CGRect(x: 100, y: 50, width: 400, height: 200)
        XCTAssertNil(SnapshotRegion.selection(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 300, y: 180), imageRect: imageRect))
        XCTAssertNil(SnapshotRegion.selection(from: CGPoint(x: 200, y: 100), to: CGPoint(x: 201, y: 101), imageRect: imageRect))
        XCTAssertEqual(
            SnapshotRegion.selection(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 0, y: 0), imageRect: imageRect),
            SnapshotRegion(x: 0, y: 0, width: 0.75, height: 0.75)
        )
    }

    func testCropKeepsOnlyTheSelectedPixels() throws {
        let bytes: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let crop = try XCTUnwrap(SnapshotRegion(x: 0.5, y: 0, width: 0.5, height: 0.5).cropped(from: image))
        XCTAssertEqual(crop.width, 1)
        XCTAssertEqual(crop.height, 1)
        // Decode the exported crop, proving the retained pixel is the top-right green pixel.
        let png = try XCTUnwrap(ImageCodec.png(crop))
        let decoded = try XCTUnwrap(ImageCodec.decode(png))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(pixel, [0, 255, 0, 255])
    }
}
