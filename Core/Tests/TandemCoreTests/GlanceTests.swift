import XCTest
@testable import TandemCore

/// Glance: the Studio's text in a see-through overlay on the Source's screen.
final class GlanceTests: XCTestCase {
    private let screen = GlanceScreen(width: 1512, height: 982, visibleFrame: GlanceFrame(x: 0, y: 0.04, width: 1, height: 0.9), isSharedDisplay: true)

    // MARK: Wire

    func testGlanceMessagesRoundTrip() throws {
        let id = UUID()
        let messages: [ControlMessage] = [
            .glanceContent(GlanceContent(documentID: id, revision: 1, text: "# Steps\n\n1. Open **Settings**", title: "Pasted", origin: .note, isStreaming: false)),
            .glanceContent(GlanceContent(documentID: id, revision: 2, text: " then ✅ 日本語", appendingToUTF8Count: 30, origin: .answer, isStreaming: true)),
            .glanceLayout(GlanceLayout(sequence: 42, isVisible: true, frame: GlanceFrame(x: 0.1, y: 0.2, width: 0.3, height: 0.4), scrollOffset: 120.5, animated: true, backgroundOpacity: 0.6, textScale: 1.25, sentAtNanos: 1_790_000_000_123_456_789)),
            .glanceLayout(GlanceLayout(sequence: 43, isVisible: false, isResync: true)),
            .glanceLayout(GlanceLayout(sequence: 44, displayID: "69733382")),
            .glanceContent(GlanceContent(documentID: id, revision: 3, text: "again", origin: .note, isStreaming: false, isResync: true)),
            .glanceStatus(GlanceStatus(state: .showing, documentID: id, revision: 2, layoutSequence: 42, frame: .standard, scrollOffset: 120.5, contentHeight: 900, viewportHeight: 300, screen: screen,
                                       displays: [GlanceDisplay(id: "1", name: "Built-in Retina Display", isShared: true), GlanceDisplay(id: "69733382", name: "Studio Display", isShared: false)])),
            .glanceStatus(GlanceStatus(state: .hiddenOnSource, documentID: nil, revision: 0, needsFullText: true, isFromYou: false, layoutSequence: 0, frame: .standard, scrollOffset: 0, contentHeight: 0, viewportHeight: 0, screen: screen))
        ]
        for message in messages {
            let encoded = try PeerMessageCodec.encode(.control(message))
            XCTAssertEqual(try PeerMessageCodec.decode(encoded), .control(message))
        }
    }

    func testLayoutMessagesStaySmall() throws {
        // Sent up to 60 times a second while dragging or scrolling, even over Bluetooth.
        let layout = GlanceLayout(sequence: 123_456, frame: GlanceFrame(x: 0.123456789, y: 0.2, width: 0.3, height: 0.4), scrollOffset: 1234.5678, sentAtNanos: 1_790_000_000_123_456_789)
        let encoded = try PeerMessageCodec.encode(.control(.glanceLayout(layout)))
        XCTAssertLessThan(encoded.count, 320)
    }

    func testSourcesAdvertiseGlance() {
        XCTAssertEqual(PeerHello.Capability.glance, "glance")
        // A Source that predates Glance can't decode it, and PeerLink skips undecodable messages.
        let json = #"{"glanceLayout":{"_0":{"sequence":1,"isVisible":true,"frame":{"x":0,"y":0,"width":0.5,"height":0.5},"scrollOffset":0,"animated":false,"backgroundOpacity":0.7,"textScale":1}}}"#
        XCTAssertEqual(try PeerMessageCodec.decode(Data([1]) + Data(json.utf8)), .control(.glanceLayout(GlanceLayout(sequence: 1, frame: GlanceFrame(x: 0, y: 0, width: 0.5, height: 0.5), backgroundOpacity: 0.7))))
    }

    // MARK: Streaming text

    func testAnswersStreamAsAppends() throws {
        var outbox = GlanceOutbox()
        let first = try XCTUnwrap(outbox.update(text: "Hello", title: nil, origin: .answer, isStreaming: true))
        XCTAssertNil(first.appendingToUTF8Count, "the first message carries the whole text")
        XCTAssertEqual(first.text, "Hello")

        let second = try XCTUnwrap(outbox.update(text: "Hello, wörld", title: nil, origin: .answer, isStreaming: true))
        XCTAssertEqual(second.appendingToUTF8Count, 5)
        XCTAssertEqual(second.text, ", wörld")
        XCTAssertEqual(second.revision, first.revision + 1)

        XCTAssertNil(outbox.update(text: "Hello, wörld", title: nil, origin: .answer, isStreaming: true), "nothing changed")

        let done = try XCTUnwrap(outbox.update(text: "Hello, wörld", title: nil, origin: .answer, isStreaming: false))
        XCTAssertEqual(done.text, "", "finishing only flips isStreaming")
        XCTAssertEqual(done.appendingToUTF8Count, "Hello, wörld".utf8.count)
        XCTAssertFalse(done.isStreaming)

        let edited = try XCTUnwrap(outbox.update(text: "Goodbye", title: nil, origin: .note, isStreaming: false))
        XCTAssertNil(edited.appendingToUTF8Count, "text that isn't an extension is sent whole")
        XCTAssertEqual(edited.text, "Goodbye")
    }

    func testTheSourceRebuildsTheStreamedText() throws {
        var outbox = GlanceOutbox()
        var document = GlanceDocument()
        // Chunks split multi-byte characters and grapheme clusters between messages.
        let chunks = ["Run `ls`", " — then 👍", "🏽 and 日本", "語\n\n```swift\nlet x = 1", "\n```\n", "Done ✅"]
        var text = ""
        for chunk in chunks {
            text += chunk
            let message = try XCTUnwrap(outbox.update(text: text, title: "Answer", origin: .answer, isStreaming: true))
            let wire = try PeerMessageCodec.decode(PeerMessageCodec.encode(.control(.glanceContent(message))))
            guard case .control(.glanceContent(let received)) = wire else { return XCTFail() }
            XCTAssertEqual(document.apply(received), .applied)
            XCTAssertEqual(document.text, text)
        }
        let final = try XCTUnwrap(outbox.update(text: text, title: "Answer", origin: .answer, isStreaming: false))
        XCTAssertEqual(document.apply(final), .applied)
        XCTAssertFalse(document.isStreaming)
        XCTAssertEqual(document.title, "Answer")
        XCTAssertEqual(document.text, chunks.joined())
    }

    func testAMissedAppendAsksForTheWholeText() throws {
        var outbox = GlanceOutbox()
        var document = GlanceDocument()
        XCTAssertEqual(document.apply(try XCTUnwrap(outbox.update(text: "one", title: nil, origin: .answer, isStreaming: true))), .applied)
        _ = outbox.update(text: "one two", title: nil, origin: .answer, isStreaming: true) // lost (the Source wasn't listening)
        let next = try XCTUnwrap(outbox.update(text: "one two three", title: nil, origin: .answer, isStreaming: true))
        XCTAssertEqual(document.apply(next), .needsFullText)
        XCTAssertEqual(document.text, "one", "a mismatched append changes nothing")

        let full = try XCTUnwrap(outbox.resync())
        XCTAssertNil(full.appendingToUTF8Count)
        XCTAssertEqual(document.apply(full), .applied)
        XCTAssertEqual(document.text, "one two three")
        // And appends resume from there.
        let more = try XCTUnwrap(outbox.update(text: "one two three four", title: nil, origin: .answer, isStreaming: false))
        XCTAssertEqual(more.appendingToUTF8Count, "one two three".utf8.count)
        XCTAssertEqual(document.apply(more), .applied)
        XCTAssertEqual(document.text, "one two three four")
    }

    func testOldRevisionsAreIgnoredButANewDocumentAlwaysReplaces() throws {
        var outbox = GlanceOutbox()
        var document = GlanceDocument()
        let first = try XCTUnwrap(outbox.update(text: "a", title: nil, origin: .note, isStreaming: false))
        let second = try XCTUnwrap(outbox.update(text: "b", title: nil, origin: .note, isStreaming: false))
        XCTAssertEqual(document.apply(second), .applied)
        XCTAssertEqual(document.apply(first), .stale)
        XCTAssertEqual(document.text, "b")

        outbox.startDocument()
        let fresh = try XCTUnwrap(outbox.update(text: "new", title: "Note", origin: .note, isStreaming: false))
        XCTAssertEqual(fresh.revision, 1, "revisions restart with each document")
        XCTAssertEqual(document.apply(fresh), .applied)
        XCTAssertEqual(document.text, "new")
        XCTAssertEqual(document.id, outbox.documentID)

        // An append for a document the Source never saw can't be applied.
        let foreign = GlanceContent(documentID: UUID(), revision: 9, text: "x", appendingToUTF8Count: 3, origin: .answer, isStreaming: true)
        XCTAssertEqual(document.apply(foreign), .needsFullText)
    }

    func testResyncAfterReconnectSendsTheWholeText() throws {
        var outbox = GlanceOutbox()
        _ = outbox.update(text: "streamed so far", title: nil, origin: .answer, isStreaming: true)
        let resent = try XCTUnwrap(outbox.resync())
        XCTAssertNil(resent.appendingToUTF8Count)
        XCTAssertEqual(resent.text, "streamed so far")
        XCTAssertTrue(resent.isStreaming)
        XCTAssertEqual(resent.isResync, true, "a resync never takes over another Studio's Glance")
        XCTAssertNil(outbox.update(text: "streamed so far, more", title: nil, origin: .answer, isStreaming: true)?.isResync)

        var empty = GlanceOutbox()
        XCTAssertNil(empty.resync(), "nothing to resend before anything was shown")
    }

    func testHugeTextIsCutAtACharacterBoundary() throws {
        var outbox = GlanceOutbox()
        let huge = String(repeating: "é👍", count: GlanceContent.maxTextBytes / 4)
        let message = try XCTUnwrap(outbox.update(text: huge, title: nil, origin: .note, isStreaming: false))
        XCTAssertLessThanOrEqual(message.text.utf8.count, GlanceContent.maxTextBytes)
        XCTAssertTrue(message.text.hasSuffix("…"))
        XCTAssertTrue(huge.hasPrefix(String(message.text.dropLast(3))))
    }

    // MARK: Placement

    func testFramesStayOnTheUsableScreen() {
        let visible = screen.visibleFrame
        let offScreen = GlanceFrame(x: 0.9, y: -0.2, width: 0.4, height: 0.3).clamped(to: visible)
        XCTAssertEqual(offScreen.maxX, visible.maxX, accuracy: 1e-9)
        XCTAssertEqual(offScreen.y, visible.y, accuracy: 1e-9)
        XCTAssertEqual(offScreen.width, 0.4, accuracy: 1e-9)

        let tooBig = GlanceFrame(x: 0, y: 0, width: 3, height: 3).clamped(to: visible)
        XCTAssertEqual(tooBig, visible)

        let tiny = GlanceFrame(x: 0.5, y: 0.5, width: 0.001, height: 0.001).clamped(to: visible, minWidth: 0.15, minHeight: 0.1)
        XCTAssertEqual(tiny.width, 0.15, accuracy: 1e-9)
        XCTAssertEqual(tiny.height, 0.1, accuracy: 1e-9)

        XCTAssertEqual(GlanceFrame(x: .nan, y: 0, width: 1, height: 1).clamped(), GlanceFrame.standard)
    }

    func testPresetsSnapInsideTheVisibleArea() {
        let visible = screen.visibleFrame
        let frame = GlanceFrame(x: 0.3, y: 0.3, width: 0.3, height: 0.4)
        let topRight = frame.placed(.topRight, in: visible, margin: 0.02)
        XCTAssertEqual(topRight.maxX, visible.maxX - 0.02, accuracy: 1e-9)
        XCTAssertEqual(topRight.y, visible.y + 0.02, accuracy: 1e-9)
        let bottomLeft = frame.placed(.bottomLeft, in: visible, margin: 0.02)
        XCTAssertEqual(bottomLeft.x, 0.02, accuracy: 1e-9)
        XCTAssertEqual(bottomLeft.maxY, visible.maxY - 0.02, accuracy: 1e-9)
        let center = frame.placed(.center, in: visible)
        XCTAssertEqual(center.x + center.width / 2, visible.x + visible.width / 2, accuracy: 1e-9)
        XCTAssertEqual(center.y + center.height / 2, visible.y + visible.height / 2, accuracy: 1e-9)
        for placement in GlancePlacement.allCases {
            let placed = frame.placed(placement, in: visible)
            XCTAssertEqual(placed.width, frame.width, accuracy: 1e-9, "\(placement) keeps the size")
            XCTAssertGreaterThanOrEqual(placed.x, visible.x - 1e-9)
            XCTAssertLessThanOrEqual(placed.maxY, visible.maxY + 1e-9)
        }
    }

    func testFramesMapOntoAppKitScreens() {
        // A second display to the right of a 1512×982 main one, with a menu bar on top.
        let screenFrame = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let frame = GlanceFrame(x: 0.5, y: 0.25, width: 0.25, height: 0.5)
        let rect = frame.rect(in: screenFrame)
        XCTAssertEqual(rect, CGRect(x: 1512 + 960, y: -200 + 270, width: 480, height: 540))
        let back = GlanceFrame(rect: rect, in: screenFrame)
        XCTAssertEqual(back.x, frame.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, frame.y, accuracy: 1e-9)
        XCTAssertEqual(back.width, frame.width, accuracy: 1e-9)
        XCTAssertEqual(back.height, frame.height, accuracy: 1e-9)
        // The menu bar (top 24 pt) is outside the visible frame.
        let visible = GlanceFrame(rect: CGRect(x: 1512, y: -200, width: 1920, height: 1056), in: screenFrame)
        XCTAssertEqual(visible.y, 24.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(visible.maxY, 1, accuracy: 1e-9)
    }

    func testLayoutFromAPeerIsMadeSafe() {
        let wild = GlanceLayout(frame: GlanceFrame(x: -5, y: 0, width: 9, height: 0.5), scrollOffset: -.infinity, backgroundOpacity: 7, textScale: .nan).sanitized
        XCTAssertEqual(wild.frame.width, 1)
        XCTAssertEqual(wild.frame.x, 0)
        XCTAssertEqual(wild.scrollOffset, 0)
        XCTAssertEqual(wild.backgroundOpacity, GlanceLayout.opacityRange.upperBound)
        XCTAssertEqual(wild.textScale, 1)
    }

    // MARK: Scrolling

    func testScrollingStaysWithinTheText() {
        XCTAssertEqual(GlanceScroll.clamp(500, content: 900, viewport: 300), 500)
        XCTAssertEqual(GlanceScroll.clamp(800, content: 900, viewport: 300), 600)
        XCTAssertEqual(GlanceScroll.clamp(-10, content: 900, viewport: 300), 0)
        XCTAssertEqual(GlanceScroll.clamp(50, content: 200, viewport: 300), 0, "short text doesn't scroll")
        XCTAssertEqual(GlanceScroll.clamp(.nan, content: 900, viewport: 300), 0)
        // Steps overlap the previous view, like Glance's.
        XCTAssertEqual(GlanceScroll.lineStep(viewport: 400), 48)
        XCTAssertEqual(GlanceScroll.lineStep(viewport: 120), 30)
        XCTAssertLessThan(GlanceScroll.pageStep(viewport: 400), 400)
        let status = GlanceStatus(state: .showing, documentID: nil, revision: 0, layoutSequence: 0, frame: .standard, scrollOffset: 0, contentHeight: 1000, viewportHeight: 250, screen: screen)
        XCTAssertEqual(status.maxScrollOffset, 750)
    }
}
