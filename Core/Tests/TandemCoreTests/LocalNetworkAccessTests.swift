import Network
import XCTest
@testable import TandemCore

final class LocalNetworkAccessTests: XCTestCase {
    private func ip(_ text: String) -> UInt32 { LocalNetworkAccess.hostOrder(IPv4Address(text)!) }

    func testReadsTheProbeConnectionState() {
        XCTAssertEqual(LocalNetworkAccess.interpret(.ready, unsatisfiedReason: nil), .allowed)
        XCTAssertEqual(LocalNetworkAccess.interpret(.waiting(.posix(.ENETUNREACH)), unsatisfiedReason: .localNetworkDenied), .denied)
        XCTAssertEqual(LocalNetworkAccess.interpret(.waiting(.posix(.ENETUNREACH)), unsatisfiedReason: .notAvailable), .unknown)
        XCTAssertEqual(LocalNetworkAccess.interpret(.failed(.posix(.ECONNREFUSED)), unsatisfiedReason: nil), .unknown)
        XCTAssertNil(LocalNetworkAccess.interpret(.preparing, unsatisfiedReason: nil))
        XCTAssertNil(LocalNetworkAccess.interpret(.setup, unsatisfiedReason: nil))
    }

    /// The router is usually the DNS server, which macOS lets every app reach, so probing it
    /// says nothing. The probe picks another host on the subnet.
    func testProbesAHostThatIsNotThisMacTheRouterOrADNSServer() {
        let mask = ip("255.255.255.0")
        XCTAssertEqual(LocalNetworkAccess.probeAddress(address: ip("192.168.1.23"), netmask: mask, avoiding: [ip("192.168.1.1")]), ip("192.168.1.254"))
        XCTAssertEqual(LocalNetworkAccess.probeAddress(address: ip("192.168.1.23"), netmask: mask, avoiding: [ip("192.168.1.254")]), ip("192.168.1.253"))
        XCTAssertEqual(LocalNetworkAccess.probeAddress(address: ip("192.168.1.254"), netmask: mask, avoiding: [ip("192.168.1.253")]), ip("192.168.1.252"))
        XCTAssertEqual(LocalNetworkAccess.probeAddress(address: ip("169.254.10.20"), netmask: ip("255.255.0.0"), avoiding: []), ip("169.254.255.254"))
        XCTAssertEqual(LocalNetworkAccess.probeAddress(address: ip("10.0.0.1"), netmask: ip("255.255.255.252"), avoiding: []), ip("10.0.0.2"))
        XCTAssertNil(LocalNetworkAccess.probeAddress(address: ip("10.0.0.1"), netmask: ip("255.255.255.254"), avoiding: []))
    }

    func testTheLiveProbeTargetIsOnTheLocalNetworkButNotExempt() throws {
        guard let target = LocalNetworkAccess.probeTarget() else { throw XCTSkip("No IPv4 local network here") }
        let host = LocalNetworkAccess.hostOrder(target)
        XCTAssertFalse(LocalNetworkAccess.exemptAddresses().contains(host))
        let networks = LocalNetworkAccess.localNetworks()
        XCTAssertTrue(networks.contains { $0.address & $0.netmask == host & $0.netmask && $0.address != host })
    }

    /// Tests run as a command-line tool, which macOS always lets onto the local network.
    func testCommandLineToolsAreNeverReportedBlocked() async {
        let access = await LocalNetworkAccess.check(timeout: 3)
        XCTAssertNotEqual(access, .denied)
    }
}
