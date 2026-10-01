import AppKit
import Network
import TandemCore
import XCTest
@testable import Tandem

@MainActor
final class GlanceOverlayTests: XCTestCase {
    func testWideCodeAndTablesAreReachableThroughVerticalScrolling() {
        let controller = GlanceOverlayController(), owner = UUID()
        defer { controller.reset() }
        let code = "```swift\n" + String(repeating: "long_identifier_", count: 400) + "\n```"
        XCTAssertNil(controller.apply(.init(revision: 1, content: .init(text: code)), from: owner, ownerName: "Studio"))
        XCTAssertGreaterThan(controller.status(for: owner).maxScrollPoints, 500)
        let cells = (1...12).map { "Column \($0)" }
        let table = "|" + cells.joined(separator: "|") + "|\n|" + cells.map { _ in "---" }.joined(separator: "|") + "|\n|" + cells.map { _ in String(repeating: "value ", count: 20) }.joined(separator: "|") + "|"
        XCTAssertNil(controller.apply(.init(revision: 2, content: .init(text: table)), from: owner, ownerName: "Studio"))
        XCTAssertGreaterThan(controller.status(for: owner).maxScrollPoints, 0)
        XCTAssertNil(controller.apply(.init(revision: 3, scrollFraction: 1), from: owner, ownerName: "Studio"))
        XCTAssertEqual(controller.status(for: owner).scrollFraction, 1, accuracy: 0.01)
    }

    func testCaptureInterruptionClearsTheOverlay() {
        let source = SourceEngine(settings: settings()), connection = connection()
        source.attach(connection)
        connection.receive(.glanceCommand(.init(revision: 1, content: .init(text: "visible"))))
        XCTAssertNotNil(source.glance.session.content)
        source.captureInterrupted(nil)
        XCTAssertNil(source.glance.session.content)
        XCTAssertFalse(source.glance.panel?.isVisible ?? false)
        source.deactivate()
    }

    func testLockClearsAndBlocksGlanceWhenSharingPauseSettingIsOff() {
        let settings = settings()
        settings.pauseWhenLocked = false
        let source = SourceEngine(settings: settings), connection = connection()
        source.attach(connection)
        connection.receive(.glanceCommand(.init(revision: 1, content: .init(text: "visible"))))
        XCTAssertNotNil(source.glance.session.content)
        source.screenLockChanged(true)
        XCTAssertTrue(source.isActive)
        XCTAssertNil(source.glance.session.content)
        connection.receive(.glanceCommand(.init(revision: 2, content: .init(text: "locked"))))
        XCTAssertNil(source.glance.session.content)
        source.screenLockChanged(false)
        connection.receive(.glanceCommand(.init(revision: 3, content: .init(text: "unlocked"))))
        XCTAssertEqual(source.glance.session.content?.text, "unlocked")
        source.deactivate()
    }
    private func connection() -> PeerConnection {
        let transport = NetworkTransport(endpoint: .hostPort(host: "127.0.0.1", port: 9), queue: DispatchQueue(label: "glance.policy"))
        let session = SecureSession(role: .initiator(mode: .pair, expectedPeerID: nil), identity: .init(id: UUID().uuidString, name: "Fixture", model: "test"), keyStore: InMemoryPairingKeyStore())
        let connection = PeerConnection(link: PeerLink(transport: transport, session: session), direction: .incoming, isPairingAttempt: false, expectedPeer: nil)
        connection.update(phase: .connected)
        return connection
    }

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "tandem.glance.\(UUID().uuidString)")!)
    }

    func testOverlayIsPassiveAndDoesNotChangeTheKeyWindow() throws {
        let controller = GlanceOverlayController(), owner = UUID()
        defer { controller.reset() }
        let keyWindow = NSApp.keyWindow
        XCTAssertNil(controller.apply(.init(revision: 1, content: .init(text: "## Keep working\n**Readable text**")), from: owner, ownerName: "Studio"))
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertTrue(panel.screen?.visibleFrame.contains(panel.frame) == true)
    }

    func testLongMarkdownScrollsAndResetRemovesContentAndWindow() {
        let controller = GlanceOverlayController(), owner = UUID()
        let text = (1...100).map { "### Step \($0)\nRead this line and continue.\n" }.joined(separator: "\n")
        XCTAssertNil(controller.apply(.init(revision: 1, content: .init(text: text)), from: owner, ownerName: "Studio"))
        XCTAssertGreaterThan(controller.status(for: owner).maxScrollPoints, 500)
        XCTAssertNil(controller.apply(.init(revision: 2, scrollFraction: 0.5), from: owner, ownerName: "Studio"))
        XCTAssertEqual(controller.status(for: owner).scrollFraction, 0.5, accuracy: 0.01)
        XCTAssertNil(controller.apply(.init(revision: 3, content: .init(text: "new text")), from: owner, ownerName: "Studio"))
        XCTAssertEqual(controller.status(for: owner).scrollFraction, 0)
        controller.reset()
        XCTAssertFalse(controller.panel?.isVisible ?? false)
        XCTAssertNil(controller.session.content)
        XCTAssertNil(controller.session.owner)
    }

    func testUnapprovedOrDisabledSourceRejectsInjection() {
        let settings = settings()
        settings.approveEachSession = true
        let source = SourceEngine(settings: settings), connection = connection()
        source.attach(connection)
        connection.receive(.glanceCommand(.init(revision: 1, content: .init(text: "not approved"))))
        XCTAssertNil(source.glance.session.content)
        settings.approveEachSession = false
        source.approve(connection.id, allow: true)
        settings.allowGlanceInject = false
        connection.receive(.glanceCommand(.init(revision: 2, content: .init(text: "disabled"))))
        XCTAssertNil(source.glance.session.content)
        source.deactivate()
    }

    func testOwnerDisconnectAndPauseClearAndPreventResurrection() {
        let source = SourceEngine(settings: settings()), connection = connection()
        source.attach(connection)
        connection.receive(.glanceCommand(.init(revision: 1, content: .init(text: "approved"))))
        XCTAssertEqual(source.glance.session.content?.text, "approved")
        source.setSharing(false)
        XCTAssertNil(source.glance.session.content)
        connection.receive(.glanceCommand(.init(revision: 2, content: .init(text: "paused"))))
        XCTAssertNil(source.glance.session.content)
        source.setSharing(true)
        connection.receive(.glanceCommand(.init(revision: 3, content: .init(text: "resumed"))))
        XCTAssertEqual(source.glance.session.content?.text, "resumed")
        source.detach(connection)
        XCTAssertNil(source.glance.session.content)
        XCTAssertFalse(source.glance.panel?.isVisible ?? false)
        source.deactivate()
    }
}
