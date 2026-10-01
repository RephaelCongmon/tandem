import TandemCore
import XCTest
@testable import Tandem

/// The Studio's Glance controls: clamping against what the Source reports, scrolling, and restore.
@MainActor
final class GlanceInjectorTests: XCTestCase {
    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "tandem.tests.\(UUID().uuidString)")!)
    }

    private func status(content: Double = 1000, viewport: Double = 300, visible: GlanceFrame = GlanceFrame(x: 0, y: 0.03, width: 1, height: 0.92)) -> GlanceStatus {
        GlanceStatus(
            state: .showing, documentID: nil, revision: 1, layoutSequence: 1, frame: .standard,
            scrollOffset: 0, contentHeight: content, viewportHeight: viewport,
            screen: GlanceScreen(width: 1728, height: 1117, visibleFrame: visible, isSharedDisplay: true)
        )
    }

    func testFramesStayOnTheSourcesUsableScreen() {
        let glance = GlanceInjector(settings: makeSettings())
        glance.handle(status())
        glance.setFrame(GlanceFrame(x: 0.9, y: 0.9, width: 0.3, height: 0.3), animated: false)
        XCTAssertEqual(glance.layout.frame.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(glance.layout.frame.maxY, 0.95, accuracy: 1e-9, "above the Dock")
        glance.setFrame(GlanceFrame(x: 0.2, y: 0.2, width: 0.01, height: 0.01), animated: false)
        XCTAssertEqual(glance.layout.frame.width, GlanceOverlayController.minimumSize.width / 1728, accuracy: 1e-9)
        glance.place(.topLeft)
        XCTAssertEqual(glance.layout.frame.y, 0.03 + 0.02, accuracy: 1e-9, "below the menu bar")
    }

    func testScrollingUsesTheSourcesMeasurements() {
        let glance = GlanceInjector(settings: makeSettings())
        glance.handle(status(content: 1000, viewport: 300))
        glance.scroll(.bottom)
        XCTAssertEqual(glance.layout.scrollOffset, 700)
        XCTAssertEqual(glance.scrollFraction, 1)
        glance.scroll(.lineDown)
        XCTAssertEqual(glance.layout.scrollOffset, 700, "nothing below the end")
        glance.scroll(.top)
        glance.scroll(.pageDown)
        XCTAssertEqual(glance.layout.scrollOffset, 255, "a page keeps a little of the last view")
        glance.scroll(.lineUp)
        XCTAssertEqual(glance.layout.scrollOffset, 255 - 48)
        glance.scroll(by: -1000)
        XCTAssertEqual(glance.layout.scrollOffset, 0)
        // The text got shorter on the Source: scrolling starts from where it really is.
        glance.scroll(.bottom)
        glance.handle(status(content: 500, viewport: 300))
        glance.scroll(.lineUp)
        XCTAssertEqual(glance.layout.scrollOffset, 200 - 48)
    }

    func testLargerTextKeepsTheSamePartInView() {
        let glance = GlanceInjector(settings: makeSettings())
        glance.handle(status(content: 2000, viewport: 300))
        glance.setScrollOffset(200, animated: false)
        glance.setTextScale(2)
        XCTAssertEqual(glance.layout.textScale, 2)
        XCTAssertEqual(glance.layout.scrollOffset, 400)
        glance.setTextScale(99)
        XCTAssertEqual(glance.layout.textScale, GlanceLayout.textScaleRange.upperBound)
    }

    func testNewTextStartsAtTheTopAndClearRemovesIt() {
        let glance = GlanceInjector(settings: makeSettings())
        glance.handle(status())
        glance.show("first", title: nil, origin: .note)
        glance.setScrollOffset(120, animated: false)
        glance.show("second", title: "Answer", origin: .answer)
        XCTAssertEqual(glance.content.text, "second")
        XCTAssertEqual(glance.content.title, "Answer")
        XCTAssertEqual(glance.layout.scrollOffset, 0)
        XCTAssertTrue(glance.layout.isVisible)
        glance.clear()
        XCTAssertFalse(glance.hasContent)
    }

    func testLiveTypingFollowsTheField() {
        let glance = GlanceInjector(settings: makeSettings())
        glance.liveTyping = true
        glance.draft = "Hel"
        XCTAssertEqual(glance.content.text, "Hel")
        glance.draft = "Hello"
        XCTAssertEqual(glance.content.text, "Hello")
        glance.liveTyping = false
        glance.draft = "Hello there"
        XCTAssertEqual(glance.content.text, "Hello", "without live typing, Show sends it")
        glance.showDraft()
        XCTAssertEqual(glance.content.text, "Hello there")
    }

    func testTheLastGlanceIsRestored() async throws {
        let settings = makeSettings()
        let glance = GlanceInjector(settings: settings)
        glance.handle(status())
        glance.show("Keep me", title: "Note", origin: .note)
        glance.setScrollOffset(40, animated: false)
        glance.setVisible(false)
        try await Task.sleep(nanoseconds: 600_000_000) // saving waits for a pause
        let saved = try XCTUnwrap(settings.glanceDocument)
        XCTAssertEqual(saved, SavedGlance(text: "Keep me", title: "Note", origin: .note, scrollOffset: 40, isVisible: false))

        let restored = GlanceInjector(settings: settings)
        XCTAssertEqual(restored.content.text, "Keep me")
        XCTAssertEqual(restored.content.title, "Note")
        XCTAssertEqual(restored.layout.scrollOffset, 40)
        XCTAssertFalse(restored.layout.isVisible)
    }

    func testALateUpdateDoesntRestartAFinishedAnswer() {
        let glance = GlanceInjector(settings: makeSettings())
        glance.followAnswers = true
        let reply = StreamingReply(threadID: UUID(), messageID: UUID(), phase: .streaming)
        reply.text = "Partial"
        glance.answerUpdated(reply, isFinal: false)
        XCTAssertTrue(glance.content.isStreaming)
        reply.text = "Partial and done."
        glance.answerUpdated(reply, isFinal: true)
        XCTAssertFalse(glance.content.isStreaming)
        glance.setScrollOffset(30, animated: false)
        // The chat's last queued flush lands after it finished.
        glance.answerUpdated(reply, isFinal: false)
        XCTAssertFalse(glance.content.isStreaming, "still finished")
        XCTAssertEqual(glance.content.text, "Partial and done.")
        XCTAssertEqual(glance.layout.scrollOffset, 30, "and not scrolled back to the top")
        // The next answer is followed as usual.
        let next = StreamingReply(threadID: reply.threadID, messageID: UUID(), phase: .streaming)
        next.text = "Next"
        glance.answerUpdated(next, isFinal: false)
        XCTAssertEqual(glance.content.text, "Next")
        XCTAssertTrue(glance.content.isStreaming)
    }

    func testResizingStopsAtTheScreenEdge() {
        let glance = GlanceInjector(settings: makeSettings())
        glance.handle(status())
        let start = GlanceFrame(x: 0.6, y: 0.5, width: 0.3, height: 0.3)
        glance.setFrame(start, animated: false)
        glance.resize(from: start, dx: 0.4, dy: 0.4)
        XCTAssertEqual(glance.layout.frame.x, 0.6, accuracy: 1e-9, "the corner it's dragged from moves, not the overlay")
        XCTAssertEqual(glance.layout.frame.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(glance.layout.frame.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(glance.layout.frame.maxY, 0.95, accuracy: 1e-9)
    }

    func testTheFrameIsKeptOnTheRealScreenOnceItsKnown() {
        let glance = GlanceInjector(settings: makeSettings())
        XCTAssertEqual(glance.layout.frame, .standard)
        // The Dock is on the right: the usable area ends at 90% of the width.
        glance.handle(status(visible: GlanceFrame(x: 0, y: 0.03, width: 0.9, height: 0.97)))
        XCTAssertEqual(glance.layout.frame.maxX, 0.9, accuracy: 1e-9)
        XCTAssertEqual(glance.layout.frame.width, GlanceFrame.standard.width, accuracy: 1e-9)
    }

    func testChoosingADisplayIsRemembered() {
        let settings = makeSettings()
        let glance = GlanceInjector(settings: settings)
        var report = status()
        XCTAssertTrue(glance.displays.isEmpty, "no menu until the Source reports several displays")
        report.displays = [GlanceDisplay(id: "1", name: "Built-in", isShared: true), GlanceDisplay(id: "2", name: "Studio Display", isShared: false)]
        glance.handle(report)
        XCTAssertEqual(glance.displays.map(\.id), ["1", "2"])
        glance.setDisplay("2")
        XCTAssertEqual(glance.layout.displayID, "2")
        XCTAssertEqual(GlanceInjector(settings: settings).layout.displayID, "2")
        glance.setDisplay(nil)
        XCTAssertNil(settings.glanceDisplayID)
    }

    func testNeedsAConnection() {
        let glance = GlanceInjector(settings: makeSettings())
        XCTAssertEqual(glance.problem, "Connect to the shared Mac to use Glance.")
        XCTAssertFalse(glance.isShowingOnSource)
    }
}
