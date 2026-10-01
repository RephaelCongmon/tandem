import TandemCore
import XCTest
@testable import Tandem

@MainActor
final class GlanceInjectControllerTests: XCTestCase {
    func testSourceCanDisableAndReenableInjectionWithoutDisconnecting() {
        var sent: [GlanceCommand] = []
        let controller = GlanceInjectController(send: { sent.append($0) })
        controller.configure(connectionID: UUID(), supported: true, available: true)
        controller.receive(.init(enabled: false, error: "Glance Inject is disabled on the shared Mac."))
        XCTAssertFalse(controller.canInject)
        let count = sent.count
        controller.inject("blocked")
        XCTAssertEqual(sent.count, count)
        XCTAssertNotNil(controller.availabilityMessage)
        controller.receive(.init(enabled: true))
        XCTAssertTrue(controller.canInject)
        controller.inject("allowed")
        XCTAssertEqual(sent.last?.content?.text, "allowed")
    }
    func testUnsupportedPeerGetsNoCommandsAndDraftSurvivesDisconnect() {
        var sent: [GlanceCommand] = []
        let controller = GlanceInjectController(send: { sent.append($0) })
        controller.draft = "my draft"
        controller.configure(connectionID: UUID(), supported: false, available: true)
        controller.inject(controller.draft)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(controller.canInject)
        XCTAssertNotNil(controller.availabilityMessage)
        controller.configure(connectionID: nil, supported: false, available: false)
        XCTAssertEqual(controller.draft, "my draft")
    }

    func testTextIsImmediateAndRapidPlacementChangesCoalesceWithoutResendingText() async throws {
        var sent: [GlanceCommand] = []
        let controller = GlanceInjectController(send: { sent.append($0) })
        controller.configure(connectionID: UUID(), supported: true, available: true)
        sent.removeAll()
        controller.inject("Hello 👋", title: "AI response")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.content?.text, "Hello 👋")
        controller.receive(.init(revision: try XCTUnwrap(sent.first).revision, visible: true, hasContent: true, isOwner: true))
        for index in 0...20 { controller.updateLayout(.init(x: Double(index) / 20)) }
        let deadline = Date().addingTimeInterval(2)
        while sent.count < 2, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(sent.count, 2)
        XCTAssertNil(sent.last?.content)
        XCTAssertEqual(sent.last?.layout?.x, 1)
        XCTAssertGreaterThan(try XCTUnwrap(sent.last).revision, try XCTUnwrap(sent.first).revision)
    }

    func testLateAcknowledgementDoesNotRewindPendingLayoutOrScroll() async throws {
        var sent: [GlanceCommand] = []
        let controller = GlanceInjectController(send: { sent.append($0) })
        controller.configure(connectionID: UUID(), supported: true, available: true)
        controller.inject("long text")
        let revision = try XCTUnwrap(sent.last).revision
        controller.receive(.init(revision: revision, visible: true, hasContent: true, isOwner: true, maxScrollPoints: 1000))
        controller.updateLayout(.init(x: 0.2))
        controller.scrollBy(80)
        controller.receive(.init(revision: revision, layout: .init(x: 0.8), visible: true, hasContent: true, isOwner: true))
        XCTAssertEqual(controller.layout.x, 0.2)
        XCTAssertEqual(controller.scrollFraction, 0.08, accuracy: 0.001)
        try? await Task.sleep(nanoseconds: 80_000_000)
        controller.receive(.init(revision: revision, layout: .init(x: 0.8), visible: true, hasContent: true, isOwner: true))
        XCTAssertEqual(controller.layout.x, 0.2)
        controller.configure(connectionID: nil, supported: false, available: false)
    }

    func testDisconnectCancelsPendingUpdatesAndReconnectNeverReplaysText() async throws {
        var sent: [GlanceCommand] = []
        let controller = GlanceInjectController(send: { sent.append($0) })
        controller.configure(connectionID: UUID(), supported: true, available: true)
        controller.inject("private text")
        controller.receive(.init(revision: try XCTUnwrap(sent.last).revision, visible: true, hasContent: true, isOwner: true))
        controller.updateLayout(.init(x: 0.1))
        let count = sent.count
        controller.configure(connectionID: nil, supported: false, available: false)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(sent.count, count)
        controller.configure(connectionID: UUID(), supported: true, available: true)
        XCTAssertEqual(sent.count, count + 1)
        XCTAssertTrue(try XCTUnwrap(sent.last).isQuery)
        XCTAssertFalse(controller.canManage)
    }

    func testOversizedTextIsRejectedBeforeTransmission() {
        var sent: [GlanceCommand] = []
        let controller = GlanceInjectController(send: { sent.append($0) })
        controller.configure(connectionID: UUID(), supported: true, available: true)
        let count = sent.count
        controller.inject(String(repeating: "x", count: GlanceContent.maximumBytes + 1))
        XCTAssertEqual(sent.count, count)
        XCTAssertNotNil(controller.error)
    }
}
