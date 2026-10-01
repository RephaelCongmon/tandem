import AppKit
import TandemCore
import XCTest
@testable import Tandem

/// The Source's overlay must never take the Mac from the person using it: no focus, no
/// activation, and every click, scroll and hover goes to the app underneath.
@MainActor
final class GlanceOverlayTests: XCTestCase {
    private final class FakeStudio: GlanceClient {
        let id = UUID()
        var glanceSenderName: String? = "Test Studio"
        var isGlanceReachable = true
        var glanceClockOffsetNanos: Int64?
        var statuses: [GlanceStatus] = []
        func sendGlanceStatus(_ status: GlanceStatus) { statuses.append(status) }
    }

    private var overlays: [GlanceOverlayController] = []

    override func tearDown() async throws {
        for overlay in overlays { overlay.teardown() }
        overlays.removeAll()
    }

    private func makeOverlay() -> GlanceOverlayController {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tandem.tests.\(UUID().uuidString)")!)
        let overlay = GlanceOverlayController(settings: settings)
        overlay.placement = { NSScreen.screens.first.map { ($0, true) } }
        overlays.append(overlay)
        return overlay
    }

    private func show(_ text: String, on overlay: GlanceOverlayController, from studio: FakeStudio, streaming: Bool = false) {
        overlay.receive(GlanceContent(documentID: UUID(), revision: 1, text: text, origin: .note, isStreaming: streaming), from: studio)
        overlay.receive(GlanceLayout(sequence: 1, isVisible: true, frame: GlanceFrame(x: 0.35, y: 0.3, width: 0.3, height: 0.35)), from: studio)
    }

    /// Lets queued main-thread work (status reports) run.
    private func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testThePanelIsMadeToStayOutOfTheWay() throws {
        let overlay = makeOverlay()
        overlay.prepare()
        let panel = try XCTUnwrap(overlay.debugPanel)
        XCTAssertFalse(panel.isVisible, "prepared hidden, before any Glance")
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating, "below menus, the menu bar, the Dock and alerts")
        XCTAssertTrue(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]))
        XCTAssertEqual(panel.sharingType, .none)
    }

    func testShowingAGlanceLeavesFocusAndClicksToTheAppInUse() throws {
        let overlay = makeOverlay()
        let studio = FakeStudio()
        let keyBefore = NSApp.keyWindow
        let mainBefore = NSApp.mainWindow
        let activeBefore = NSApp.isActive
        show("# Notes\n\nSomething to read while working.", on: overlay, from: studio)
        let panel = try XCTUnwrap(overlay.debugPanel)
        XCTAssertTrue(overlay.isOnScreen)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertTrue(NSApp.keyWindow === keyBefore, "the key window didn't change")
        XCTAssertTrue(NSApp.mainWindow === mainBefore)
        XCTAssertEqual(NSApp.isActive, activeBefore, "showing it doesn't activate Tandem")

        // A click in the middle of the overlay goes to whatever is underneath. (Once it has
        // drawn: macOS lets clicks through a window's transparent pixels anyway.)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.ignoresMouseEvents = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let whenClickable = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
        panel.ignoresMouseEvents = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let passThrough = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
        XCTAssertEqual(whenClickable, panel.windowNumber, "the check can see the overlay when it takes clicks")
        XCTAssertNotEqual(passThrough, panel.windowNumber, "but it doesn't")

        // Moving, scrolling and restyling it at speed changes nothing either.
        for step in 1...30 {
            overlay.receive(GlanceLayout(sequence: UInt64(1 + step), isVisible: true, frame: GlanceFrame(x: 0.2 + Double(step) * 0.005, y: 0.3, width: 0.3, height: 0.35), scrollOffset: Double(step), animated: step.isMultiple(of: 10), backgroundOpacity: 0.5, textScale: 1.1), from: studio)
        }
        drain()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertEqual(NSApp.isActive, activeBefore)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testItAlwaysStaysOffTheMenuBarAndDock() throws {
        let overlay = makeOverlay()
        let studio = FakeStudio()
        show("text", on: overlay, from: studio)
        overlay.receive(GlanceLayout(sequence: 2, isVisible: true, frame: GlanceFrame(x: -1, y: -1, width: 3, height: 3)), from: studio)
        let panel = try XCTUnwrap(overlay.debugPanel)
        let visible = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(panel.frame), "\(panel.frame) inside \(visible)")
    }

    func testTheShortcutIsOnlyNeededWhileThereIsAGlance() {
        let overlay = makeOverlay()
        let studio = FakeStudio()
        var changes: [Bool] = []
        overlay.onHasGlanceChanged = { changes.append($0) }
        let id = UUID()
        var text = ""
        for (revision, word) in ["Writing", " an", " answer", " word", " by", " word."].enumerated() {
            let base = text.utf8.count
            text += word
            overlay.receive(GlanceContent(documentID: id, revision: revision + 1, text: word, appendingToUTF8Count: revision == 0 ? nil : base, origin: .answer, isStreaming: true), from: studio)
        }
        XCTAssertEqual(overlay.document.text, text)
        XCTAssertEqual(changes, [true], "streaming words don't count as changes")
        overlay.receive(GlanceContent(documentID: UUID(), revision: 1, text: "", origin: .note, isStreaming: false), from: studio)
        XCTAssertEqual(changes, [true, false])
    }

    func testADisconnectEndsWriting() {
        let overlay = makeOverlay()
        let studio = FakeStudio()
        show("Half an answ", on: overlay, from: studio, streaming: true)
        XCTAssertTrue(overlay.document.isStreaming)
        overlay.connectionClosed(studio.id)
        XCTAssertFalse(overlay.document.isStreaming, "no endless “Writing…”")
        XCTAssertTrue(overlay.hasGlance, "the text stays up")
    }

    func testThePersonHereCanHideIt() throws {
        let overlay = makeOverlay()
        let studio = FakeStudio()
        show("text", on: overlay, from: studio)
        overlay.toggleHiddenHere()
        let panel = try XCTUnwrap(overlay.debugPanel)
        XCTAssertFalse(panel.isVisible)
        // The Studio moving it doesn't bring it back.
        overlay.receive(GlanceLayout(sequence: 5, isVisible: true, frame: GlanceFrame(x: 0.1, y: 0.1, width: 0.3, height: 0.3)), from: studio)
        XCTAssertFalse(panel.isVisible)
        drain()
        XCTAssertEqual(studio.statuses.last?.state, .hiddenOnSource)
        overlay.toggleHiddenHere()
        XCTAssertTrue(panel.isVisible)
    }
}
