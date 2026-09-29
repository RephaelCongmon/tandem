import XCTest
@testable import TandemCore

final class SmokeTests: XCTestCase {
    func testLinkKindNames() {
        XCTAssertEqual(LinkKind.thunderbolt.displayName, "Thunderbolt Cable")
    }
}
