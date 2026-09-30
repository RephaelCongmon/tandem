import XCTest
@testable import TandemCore

final class PeerUpdateWireTests: XCTestCase {
    func testMessagesRoundTrip() throws {
        let id = UUID()
        let controls: [ControlMessage] = [
            .updateOffer(UpdateOffer(id: id, version: "1.4.0", build: "7", byteCount: 8_000_000, sha256: String(repeating: "a", count: 64))),
            .updateReply(UpdateReply(id: id, accepted: false, reason: "Turned off on this Mac.")),
            .updateStatus(UpdateTransferStatus(id: id, phase: .receiving, fraction: 0.5)),
            .updateStatus(UpdateTransferStatus(id: id, phase: .failed, message: "Not signed by the same developer."))
        ]
        for control in controls {
            XCTAssertEqual(try PeerMessageCodec.decode(PeerMessageCodec.encode(.control(control))), .control(control))
        }
        let chunk = UpdateChunk(offerID: id, index: 3, count: 9, data: Data((0..<1000).map { UInt8($0 % 251) }))
        XCTAssertEqual(try PeerMessageCodec.decode(PeerMessageCodec.encode(.updateChunk(chunk))), .updateChunk(chunk))
        var bad = try PeerMessageCodec.encode(.updateChunk(UpdateChunk(offerID: id, index: 0, count: 1, data: Data([1]))))
        bad[20] = 9 // index 9 of 1
        XCTAssertThrowsError(try PeerMessageCodec.decode(bad))
    }
}

final class UpdatePackageAssemblerTests: XCTestCase {
    private func package(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }) }

    private func offer(for data: Data, id: UUID = UUID()) -> UpdateOffer {
        UpdateOffer(id: id, version: "9.0.0", build: "1", byteCount: data.count, sha256: FileTools.sha256(of: data))
    }

    private func chunks(_ data: Data, id: UUID, size: Int = 1_000) -> [UpdateChunk] {
        let count = (data.count + size - 1) / size
        return (0..<count).map { UpdateChunk(offerID: id, index: $0, count: count, data: data.subdata(in: ($0 * size)..<min(data.count, ($0 + 1) * size))) }
    }

    func testAssemblesAnIntactPackage() {
        let data = package(10_500)
        let offer = offer(for: data)
        var assembler = UpdatePackageAssembler()
        XCTAssertNil(assembler.begin(offer))
        XCTAssertEqual(assembler.begin(offer), "Another update is already arriving.")
        var events: [UpdatePackageAssembler.Event] = []
        for chunk in chunks(data, id: offer.id).reversed() {
            if let event = assembler.receive(chunk) { events.append(event) }
        }
        XCTAssertEqual(events.last, .completed(data))
        XCTAssertTrue(events.dropLast().allSatisfy { if case .progress = $0 { return true } else { return false } })
        XCTAssertFalse(assembler.isBusy)
    }

    func testRejectsDamagedOrOversizedPackages() {
        var data = package(5_000)
        let offer = offer(for: data)
        data[10] ^= 0xFF
        var assembler = UpdatePackageAssembler()
        XCTAssertNil(assembler.begin(offer))
        let last = chunks(data, id: offer.id).compactMap { assembler.receive($0) }.last
        XCTAssertEqual(last, .failed("The update was damaged on the way (checksum mismatch)."))

        XCTAssertEqual(assembler.begin(UpdateOffer(version: "9", build: "1", byteCount: UpdatePackageAssembler.maxBytes + 1, sha256: String(repeating: "0", count: 64))), "The update is too large.")
        XCTAssertEqual(assembler.begin(UpdateOffer(version: "9", build: "1", byteCount: 10, sha256: "nope")), "The update has no valid checksum.")

        let good = package(3_000)
        let second = self.offer(for: good)
        XCTAssertNil(assembler.begin(second))
        var tooBig = chunks(good, id: second.id)
        tooBig[0].data.append(contentsOf: [1, 2, 3])
        let failure = tooBig.compactMap { assembler.receive($0) }.first { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(failure, .failed("The update was larger than announced."))
    }

    func testIgnoresChunksOfOtherOffers() {
        let data = package(2_000)
        let offer = offer(for: data)
        var assembler = UpdatePackageAssembler()
        XCTAssertNil(assembler.begin(offer))
        XCTAssertNil(assembler.receive(UpdateChunk(offerID: UUID(), index: 0, count: 1, data: data)))
        XCTAssertTrue(assembler.isBusy)
    }
}
