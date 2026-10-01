import CoreGraphics
import XCTest
@testable import TandemCore

final class GlanceInjectTests: XCTestCase {
    func testFormerOwnerCannotReplayOldContentAfterTakeoverOrClear() {
        var session = GlanceSession()
        let first = UUID(), second = UUID()
        XCTAssertNil(session.apply(.init(revision: 5, content: .init(text: "first")), from: first))
        XCTAssertNil(session.apply(.init(revision: 1, content: .init(text: "second")), from: second))
        XCTAssertNotNil(session.apply(.init(revision: 5, content: .init(text: "old first")), from: first))
        XCTAssertEqual(session.content?.text, "second")
        XCTAssertNil(session.apply(.init(revision: 2, clear: true), from: second))
        XCTAssertNotNil(session.apply(.init(revision: 1, content: .init(text: "old second")), from: second))
        XCTAssertNil(session.content)
        XCTAssertNil(session.apply(.init(revision: 6, content: .init(text: "new first")), from: first))
        XCTAssertEqual(session.content?.text, "new first")
    }
    func testCommandAndStatusRoundTripOverTheRealWireCodec() throws {
        let command = GlanceCommand(revision: 7, content: .init(text: "## Hello 👋\n```swift\nprint(42)\n```", title: "AI response"), layout: .init(x: 0.6, y: 0.1), visible: true, scrollFraction: 0.3)
        let status = GlanceStatus(revision: 7, layout: command.layout!, visible: true, hasContent: true, isOwner: true, scrollFraction: 0.3, maxScrollPoints: 1234, displays: [.init(id: "1", name: "Display", width: 1440, height: 900)])
        for control in [ControlMessage.glanceCommand(command), .glanceStatus(status)] {
            XCTAssertEqual(try PeerMessageCodec.decode(PeerMessageCodec.encode(.control(control))), .control(control))
        }
    }

    func testOnlyContentInjectionTransfersOwnershipAndOldRevisionsCannotRewind() {
        let first = UUID(), second = UUID()
        var session = GlanceSession()
        XCTAssertNil(session.apply(.init(revision: 1, content: .init(text: "first")), from: first))
        XCTAssertEqual(session.owner, first)
        XCTAssertTrue(session.visible)
        XCTAssertNotNil(session.apply(.init(revision: 2, layout: .init(x: 0.1)), from: second))
        XCTAssertNil(session.apply(.init(revision: 3, layout: .init(x: 0.3)), from: first))
        XCTAssertNotNil(session.apply(.init(revision: 2, layout: .init(x: 0.8)), from: first))
        XCTAssertEqual(session.layout.x, 0.3)
        XCTAssertNil(session.apply(.init(revision: 1, content: .init(text: "second")), from: second))
        XCTAssertEqual(session.owner, second)
        XCTAssertEqual(session.content?.text, "second")
        XCTAssertNotNil(session.apply(.init(revision: 4, visible: false), from: first))
    }

    func testInvalidContentAndNonFiniteGeometryLeaveExistingContentUntouched() {
        let owner = UUID()
        var session = GlanceSession()
        XCTAssertNil(session.apply(.init(revision: 1, content: .init(text: "keep me")), from: owner))
        XCTAssertNotNil(session.apply(.init(revision: 2, content: .init(text: String(repeating: "👋", count: 20_000))), from: owner))
        XCTAssertNotNil(session.apply(.init(revision: 2, content: .init(text: " \n")), from: owner))
        XCTAssertNotNil(session.apply(.init(revision: 2, layout: .init(x: .nan)), from: owner))
        XCTAssertNotNil(session.apply(.init(revision: 2, scrollFraction: .infinity), from: owner))
        XCTAssertEqual(session.content?.text, "keep me")
        XCTAssertEqual(session.revision, 1)
        XCTAssertEqual(session.scrollFraction, 0)
    }

    func testScrollAndLayoutAreBoundedAndClearReleasesTheOwner() {
        let owner = UUID()
        var session = GlanceSession()
        XCTAssertNil(session.apply(.init(revision: 1, content: .init(text: "test"), layout: .init(x: -3, y: 5, width: 8, height: -9, opacity: 4, fontSize: -6), scrollFraction: 8), from: owner))
        XCTAssertEqual(session.layout.x, 0)
        XCTAssertEqual(session.layout.y, 1)
        XCTAssertEqual(session.layout.width, 0.85)
        XCTAssertEqual(session.layout.height, 0.18)
        XCTAssertEqual(session.layout.opacity, 0.95)
        XCTAssertEqual(session.layout.fontSize, 12)
        XCTAssertEqual(session.scrollFraction, 1)
        XCTAssertNil(session.apply(.init(revision: 2, clear: true), from: owner))
        XCTAssertNil(session.owner)
        XCTAssertNil(session.content)
        XCTAssertFalse(session.visible)
        XCTAssertEqual(session.scrollFraction, 0)
    }

    func testTopLeftPlacementFitsNegativeOriginAndTinyDisplays() {
        let layout = GlanceLayout(x: 1, y: 0, width: 0.4, height: 0.4)
        let visible = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = layout.frame(in: visible)
        XCTAssertEqual(frame.maxX, visible.maxX)
        XCTAssertEqual(frame.maxY, visible.maxY)
        XCTAssertTrue(visible.contains(frame))
        let tiny = CGRect(x: 0, y: 0, width: 250, height: 100)
        XCTAssertTrue(tiny.contains(layout.frame(in: tiny)))
    }
}
