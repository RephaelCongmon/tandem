import Network
import XCTest
@testable import TandemCore

final class BonjourListenerTests: XCTestCase {
    /// Every reconnect (after sleep, a network change or a dropped link) is a new connection, so
    /// the Source's listener must keep taking them for as long as it runs. It once stopped after 8.
    func testKeepsAcceptingConnectionsForAsLongAsItRuns() throws {
        let identity = DeviceIdentity(id: UUID().uuidString, name: "Listener Test", model: "Mac")
        let listener = BonjourListener(identity: identity, role: .source, queue: DispatchQueue(label: "test.listener"), advertises: false)
        let lock = NSLock()
        var port: UInt16 = 0
        var delivered = 0
        var waiting: XCTestExpectation?

        let ready = expectation(description: "listening")
        listener.onStateChange = { state in
            guard case .ready(let readyPort) = state else { return }
            lock.lock(); defer { lock.unlock() }
            guard port == 0 else { return }
            port = readyPort
            ready.fulfill()
        }
        listener.onIncomingTransport = { transport in
            lock.lock()
            delivered += 1
            let expectation = waiting
            lock.unlock()
            transport.queue.async {
                transport.start()
                transport.close()
            }
            expectation?.fulfill()
        }
        listener.start()
        defer { listener.stop() }
        wait(for: [ready], timeout: 5)

        let count = 12
        for attempt in 1...count {
            let accepted = expectation(description: "connection \(attempt) reaches Tandem")
            lock.lock(); waiting = accepted; lock.unlock()
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: DispatchQueue(label: "test.client"))
            wait(for: [accepted], timeout: 3)
            connection.cancel()
        }
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(delivered, count)
    }
}
