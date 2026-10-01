import XCTest
@testable import TandemCore

/// The region tool: each drag freezes the frame on screen and asks the Source for a still.
final class RegionToolTests: XCTestCase {
    func testTheFrozenFrameIsCurrentOnlyWhenNothingNewerWasCaptured() {
        XCTAssertTrue(FrozenFrame.isCurrent(displayed: 1_000, latestCaptured: 1_000))
        XCTAssertFalse(FrozenFrame.isCurrent(displayed: 1_000, latestCaptured: 1_001))
        // No frame on screen, or no live stream on the Source: send a preview.
        XCTAssertFalse(FrozenFrame.isCurrent(displayed: nil, latestCaptured: 1_000))
        XCTAssertFalse(FrozenFrame.isCurrent(displayed: 1_000, latestCaptured: nil))
    }

    func testFreezeRequestCarriesTheDisplayedFrame() throws {
        let request = SnapshotRequest(trigger: .manual, maxDimension: 1600, quality: 0.8, prepareRegionSelection: true, displayedFrameNanos: 1_790_812_345_678_901_234)
        let decoded = try PeerMessageCodec.decode(PeerMessageCodec.encode(.control(.snapshotRequest(request))))
        XCTAssertEqual(decoded, .control(.snapshotRequest(request)))
        guard case .control(.snapshotRequest(let copy)) = decoded else { return XCTFail() }
        XCTAssertEqual(copy.displayedFrameNanos, 1_790_812_345_678_901_234)
    }

    func testFreezeRequestsFromTheSheetStillDecode() throws {
        // What a 1.6.1 Studio sends: no displayed frame, so the Source always sends a preview.
        let json = #"{"id":"8D6B4E0C-3F0A-4C57-9B7E-2B1B7B9C2E11","trigger":"manual","maxDimension":1600,"quality":0.8,"prepareRegionSelection":true}"#
        let request = try JSONDecoder().decode(SnapshotRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.prepareRegionSelection, true)
        XCTAssertNil(request.displayedFrameNanos)
    }

    func testWholeScreenCoversEveryPixel() {
        XCTAssertEqual(SnapshotRegion.full.pixelRect(width: 3024, height: 1964), CGRect(x: 0, y: 0, width: 3024, height: 1964))
    }

    func testSourcesAdvertiseTheFastRegionTool() {
        XCTAssertEqual(PeerHello.Capability.regionTool, "regionTool")
        XCTAssertNotEqual(PeerHello.Capability.regionTool, PeerHello.Capability.regionSnapshots)
    }
}
