import Network
import XCTest
@testable import TandemCore

final class LocalNetworkAccessTests: XCTestCase {
    func testReadsTheProbeConnectionState() {
        XCTAssertEqual(LocalNetworkAccess.interpret(.ready, unsatisfiedReason: nil), .allowed)
        XCTAssertEqual(LocalNetworkAccess.interpret(.waiting(.posix(.ENETUNREACH)), unsatisfiedReason: .localNetworkDenied), .denied)
        XCTAssertEqual(LocalNetworkAccess.interpret(.waiting(.posix(.ENETUNREACH)), unsatisfiedReason: .notAvailable), .unknown)
        XCTAssertEqual(LocalNetworkAccess.interpret(.failed(.posix(.ECONNREFUSED)), unsatisfiedReason: nil), .unknown)
        XCTAssertNil(LocalNetworkAccess.interpret(.preparing, unsatisfiedReason: nil))
        XCTAssertNil(LocalNetworkAccess.interpret(.setup, unsatisfiedReason: nil))
    }

    /// Tests run as a command-line tool, which macOS always lets onto the local network.
    func testCommandLineToolsAreNeverReportedBlocked() async {
        let access = await LocalNetworkAccess.check(timeout: 3)
        XCTAssertNotEqual(access, .denied)
    }
}
