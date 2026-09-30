import Foundation
import Observation
import os
import TandemCore

/// Keeps the shared Mac on the same Tandem as this one. When the Source connects with an older
/// version, the Studio sends it its own signed app over the encrypted link; the Source checks
/// the developer signature, installs it and restarts. So the Source never needs its own access
/// to the (private) release feed, and Update Now on the Studio updates both Macs.
@MainActor
@Observable
final class SharedMacUpdater {
    enum State: Equatable {
        case idle
        case preparing
        case sending(Double)
        case installing(String)
        /// The Source restarts with the new version.
        case restarting
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The version the Source ran when it connected.
    private(set) var sourceVersion: AppVersion?
    private(set) var sourceName: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored weak var toasts: ToastCenter?
    /// The Source is about to restart: reconnect quickly instead of backing off.
    @ObservationIgnored var onSourceRestarting: (() -> Void)?
    @ObservationIgnored private var connection: PeerConnection?
    @ObservationIgnored private var offer: UpdateOffer?
    @ObservationIgnored private var package: Data?
    /// The version this Studio last sent, so a reconnect with it counts as success.
    @ObservationIgnored private var sentVersion: AppVersion?
    @ObservationIgnored private var offeredConnections: Set<UUID> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Updates")

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var currentVersion: AppVersion { AppVersion.current ?? AppVersion("0")! }

    /// The Source runs an older Tandem that can take an update from here.
    var canUpdateSource: Bool {
        guard let connection, connection.isConnected, connection.peerAcceptsUpdates, let sourceVersion else { return false }
        return sourceVersion < currentVersion && AppEnvironment.peerUpdatesEnabled
    }

    var isBusy: Bool {
        switch state {
        case .preparing, .sending, .installing, .restarting: return true
        case .idle, .done, .failed: return false
        }
    }

    // MARK: Connection events

    /// The Source said hello: update it automatically if it's behind (and not over Bluetooth,
    /// where 8 MB would take minutes).
    func sourceConnected(_ connection: PeerConnection, hello: PeerHello) {
        self.connection = connection
        sourceName = connection.peer?.name
        sourceVersion = AppVersion(hello.appVersion)
        if let sentVersion, let sourceVersion, sourceVersion >= sentVersion {
            state = .done(sourceVersion.description)
            log.notice("The shared Mac is now on Tandem \(sourceVersion.description, privacy: .public)")
            toasts?.show("\(sourceName ?? "The shared Mac") is now on Tandem \(sourceVersion)", systemImage: "checkmark.circle.fill", style: .success)
            self.sentVersion = nil
            return
        }
        if case .restarting = state { return }
        guard settings.updateSharedMac, canUpdateSource, !connection.linkKind.isConstrained,
              !offeredConnections.contains(connection.id) else { return }
        offeredConnections.insert(connection.id)
        updateSource()
    }

    func sourceDisconnected(_ connection: PeerConnection) {
        guard self.connection?.id == connection.id else { return }
        self.connection = nil
        offer = nil
        switch state {
        case .restarting:
            break // expected: it reconnects with the new version
        case .preparing, .sending, .installing:
            state = .failed("\(sourceName ?? "The shared Mac") disconnected during the update.")
        case .idle, .done, .failed:
            break
        }
    }

    // MARK: Sending

    /// Sends this Tandem to the Source (automatically, or from Settings › General › Updates).
    func updateSource() {
        guard let connection, canUpdateSource, !isBusy else { return }
        state = .preparing
        let version = currentVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        Task {
            do {
                let data = try await Self.packageThisApp(version: version)
                let offer = UpdateOffer(version: version.description, build: build, byteCount: data.count, sha256: FileTools.sha256(of: data))
                self.package = data
                self.offer = offer
                self.state = .sending(0)
                self.log.notice("Offering Tandem \(version.description, privacy: .public) to the shared Mac (\(data.count) bytes)")
                connection.send(.control(.updateOffer(offer)))
                self.toasts?.show("Updating \(self.sourceName ?? "the shared Mac") to Tandem \(version)…", systemImage: "arrow.down.circle")
            } catch {
                self.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func handle(_ message: ControlMessage) {
        switch message {
        case .updateReply(let reply):
            guard reply.id == offer?.id, let package, let connection else { return }
            guard reply.accepted else {
                fail(reply.reason ?? "The shared Mac declined the update.")
                return
            }
            connection.sendUpdatePackage(offerID: reply.id, data: package)
        case .updateStatus(let status):
            guard status.id == offer?.id else { return }
            switch status.phase {
            case .receiving: state = .sending(status.fraction ?? 0)
            case .verifying: state = .installing("Checking the signature…")
            case .installing: state = .installing("Installing…")
            case .restarting:
                state = .restarting
                sentVersion = offer.flatMap { AppVersion($0.version) }
                package = nil
                onSourceRestarting?()
            case .failed: fail(status.message ?? "The shared Mac couldn't install the update.")
            }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        package = nil
        offer = nil
        log.error("Updating the shared Mac failed: \(message, privacy: .public)")
        toasts?.show("Couldn't update \(sourceName ?? "the shared Mac"): \(message)", systemImage: "exclamationmark.triangle.fill", style: .warning)
    }

    /// A zip of the running app (signed, so the Source can check it came from the same developer).
    private static func packageThisApp(version: AppVersion) async throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TandemSharedUpdate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("Tandem-\(version).zip")
        if !FileManager.default.fileExists(atPath: archive.path) {
            try await FileTools.zip(Bundle.main.bundleURL, to: archive)
        }
        return try Data(contentsOf: archive)
    }
}
