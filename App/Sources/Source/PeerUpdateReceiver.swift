import Foundation
import os
import TandemCore

/// The Source side of updates sent by the Studio: accepts only newer versions from an approved
/// Studio, collects the package off the main thread, and installs it only if it's the same app
/// signed by the same developer team as this copy. Then Tandem restarts into it.
@MainActor
final class PeerUpdateReceiver {
    private let settings: SettingsStore
    private let queue = DispatchQueue(label: "tandem.update.receive", qos: .utility)
    private let assembler = Locked(UpdatePackageAssembler())
    private var connection: PeerConnection?
    private var offer: UpdateOffer?
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Updates")

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var isBusy: Bool { offer != nil }

    /// Why an offer from an approved Studio can't be taken, if it can't.
    func refusal(for offer: UpdateOffer) -> String? {
        guard AppEnvironment.peerUpdatesEnabled else { return "This copy of Tandem doesn't take updates from the other Mac." }
        guard settings.acceptPeerUpdates else { return "Updates from the other Mac are turned off on \(DeviceIdentity.systemName)." }
        guard let version = AppVersion(offer.version), let current = AppVersion.current, version > current else {
            return "\(DeviceIdentity.systemName) already has this version or a newer one."
        }
        guard CodeSignature.currentTeamIdentifier() != nil else {
            return "This copy of Tandem isn't signed by a developer team, so it can't check updates."
        }
        return nil
    }

    func handle(_ offer: UpdateOffer, from connection: PeerConnection) {
        if let reason = refusal(for: offer) ?? (isBusy ? "An update is already arriving." : nil) {
            connection.send(.control(.updateReply(UpdateReply(id: offer.id, accepted: false, reason: reason))))
            return
        }
        if let reason = assembler.value.begin(offer) {
            connection.send(.control(.updateReply(UpdateReply(id: offer.id, accepted: false, reason: reason))))
            return
        }
        self.offer = offer
        self.connection = connection
        log.notice("Receiving Tandem \(offer.version, privacy: .public) from \(connection.peer?.name ?? "the Studio", privacy: .private)")
        let assembler = self.assembler
        let queue = self.queue
        connection.updateSink.value = { [weak self] chunk in
            queue.async {
                var copy = assembler.value
                let event = copy.receive(chunk)
                assembler.value = copy
                guard let event else { return }
                onMain { self?.progress(event, offerID: chunk.offerID) }
            }
        }
        connection.send(.control(.updateReply(UpdateReply(id: offer.id, accepted: true))))
    }

    /// The Studio went away mid-transfer.
    func connectionClosed(_ connection: PeerConnection) {
        guard self.connection?.id == connection.id else { return }
        finish()
    }

    private func progress(_ event: UpdatePackageAssembler.Event, offerID: UUID) {
        guard let offer, offer.id == offerID, let connection else { return }
        switch event {
        case .progress(let fraction):
            connection.send(.control(.updateStatus(UpdateTransferStatus(id: offerID, phase: .receiving, fraction: fraction))))
        case .failed(let reason):
            report(.failed, message: reason)
            finish()
        case .completed(let data):
            connection.updateSink.value = nil
            Task { await install(data, offer: offer) }
        }
    }

    private func install(_ data: Data, offer: UpdateOffer) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TandemPeerUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let archive = folder.appendingPathComponent("Tandem-\(offer.version).zip")
            try data.write(to: archive)
            report(.verifying)
            guard let version = AppVersion(offer.version), let team = CodeSignature.currentTeamIdentifier() else {
                throw UpdateError.invalidPackage("The update's version isn't valid.")
            }
            let app = try await UpdateInstaller.prepare(
                archive: archive,
                expectedVersion: version,
                bundleIdentifier: AppEnvironment.bundleIdentifier,
                teamIdentifier: team
            )
            report(.installing)
            let target = UpdateInstaller.installLocation(for: Bundle.main.bundleURL)
            try UpdateInstaller.install(app, at: target)
            try? FileManager.default.removeItem(at: folder)
            log.notice("Installed Tandem \(offer.version, privacy: .public) from the Studio at \(target.path, privacy: .public); restarting")
            report(.restarting)
            // Let the status reach the Studio before this process quits.
            try await Task.sleep(nanoseconds: 700_000_000)
            try AppRelauncher.relaunch(into: target)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Update from the Studio failed: \(message, privacy: .public)")
            report(.failed, message: message)
            finish()
        }
    }

    private func report(_ phase: UpdateTransferStatus.Phase, message: String? = nil) {
        guard let offer, let connection else { return }
        connection.send(.control(.updateStatus(UpdateTransferStatus(id: offer.id, phase: phase, message: message))))
    }

    private func finish() {
        connection?.updateSink.value = nil
        connection = nil
        offer = nil
        var copy = assembler.value
        copy.reset()
        assembler.value = copy
    }
}
