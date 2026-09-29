import CoreBluetooth
import Foundation
import os

/// Source-side Bluetooth LE fallback: publishes an L2CAP channel, exposes its PSM and this
/// Mac's `BluetoothPeerInfo` through a small read-only GATT service, advertises that
/// service, and hands every channel a Studio opens to `onIncomingTransport`.
///
/// Threading: create and use on `queue`. The `CBPeripheralManager` runs on `queue`, and every
/// callback (including the transports it creates) is delivered there.
///
/// The channel is published with `withEncryption: false`: the layer above encrypts end to
/// end, so no BLE pairing is needed. The manager (and with it the system Bluetooth
/// permission prompt) is created on the first `start()`. After a Bluetooth power cycle the
/// channel is re-published and the service re-added automatically; the PSM may change, which
/// the browser copes with by re-reading the PSM characteristic.
public final class BluetoothAdvertiser: NSObject, CBPeripheralManagerDelegate {
    /// Longest delay between retries after a failed publish or service registration.
    private static let maxRetryDelay: TimeInterval = 30

    /// The queue all methods must be called on and all callbacks are delivered on.
    public let queue: DispatchQueue

    /// Called on `queue` with each newly opened incoming channel, wrapped in a transport
    /// that has not been started yet. The receiver owns the transport: install callbacks,
    /// call `start()`, and keep a strong reference (a dropped transport closes its channel).
    /// Channels that arrive while this is `nil` are closed.
    public var onIncomingTransport: ((StreamPairTransport) -> Void)?

    /// Called on `queue` whenever `availability` changes.
    public var onStateChange: ((BluetoothAvailability) -> Void)?

    /// The latest Bluetooth availability reported by CoreBluetooth.
    public private(set) var availability: BluetoothAvailability = .unknown

    /// The identity published in the info characteristic and advertisement.
    public private(set) var info: BluetoothPeerInfo

    /// The currently published L2CAP PSM, if any.
    public private(set) var publishedPSM: CBL2CAPPSM?

    /// Whether `start()` has been called without a matching `stop()`.
    public private(set) var isRunning = false

    private var manager: CBPeripheralManager?
    private var isPublishing = false
    private var service: CBMutableService?
    private var isAddingService = false
    private var needsServiceRebuild = false
    private var retryWork: DispatchWorkItem?
    private var consecutiveFailures = 0

    /// Creates an idle advertiser. Nothing touches Bluetooth until `start()`.
    ///
    /// - Parameters:
    ///   - queue: Serial queue for the peripheral manager, all calls and all callbacks.
    ///   - info: Identity to publish; see `updateInfo(_:)`.
    public init(queue: DispatchQueue, info: BluetoothPeerInfo) {
        self.queue = queue
        self.info = info
        super.init()
    }

    deinit {
        retryWork?.cancel()
    }

    // MARK: - Public API

    /// Starts publishing and advertising (as soon as Bluetooth is powered on). Idempotent.
    public func start() {
        BluetoothInternals.assertOnQueue(queue)
        guard !isRunning else { return }
        isRunning = true
        consecutiveFailures = 0
        if let manager {
            if manager.state == .poweredOn { publishIfNeeded() }
        } else {
            // The delegate receives the initial state, which triggers publishing.
            manager = CBPeripheralManager(
                delegate: self, queue: queue,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        }
    }

    /// Stops advertising, removes the service and unpublishes the channel. Transports that
    /// are already open stay open. Idempotent.
    public func stop() {
        BluetoothInternals.assertOnQueue(queue)
        guard isRunning else { return }
        isRunning = false
        cancelRetry()
        needsServiceRebuild = false
        guard let manager, manager.state == .poweredOn else {
            resetPublishedState()
            return
        }
        if manager.isAdvertising { manager.stopAdvertising() }
        if let service {
            manager.remove(service)
        }
        if let psm = publishedPSM {
            manager.unpublishL2CAPChannel(psm)
        }
        // A publish still in flight is unpublished when its callback arrives.
        service = nil
        isAddingService = false
        publishedPSM = nil
        BluetoothInternals.logger.info("Bluetooth advertiser stopped")
    }

    /// Replaces the published identity. While running, the GATT service is rebuilt and the
    /// advertisement restarted so Studios see the new values.
    public func updateInfo(_ info: BluetoothPeerInfo) {
        BluetoothInternals.assertOnQueue(queue)
        guard info != self.info else { return }
        self.info = info
        guard isRunning, publishedPSM != nil else { return }
        if isAddingService {
            needsServiceRebuild = true
        } else {
            rebuildService()
        }
    }

    // MARK: - Publishing

    private func publishIfNeeded() {
        guard isRunning, let manager, manager.state == .poweredOn else { return }
        guard !isPublishing else { return }
        if publishedPSM != nil {
            if service == nil { installService() }
            return
        }
        isPublishing = true
        manager.publishL2CAPChannel(withEncryption: false)
    }

    private func installService() {
        guard isRunning, let manager, manager.state == .poweredOn, let psm = publishedPSM else { return }
        guard service == nil, !isAddingService else { return }
        let psmCharacteristic = CBMutableCharacteristic(
            type: BluetoothConstants.psmCharacteristicUUID,
            properties: [.read],
            value: BluetoothConstants.encodePSM(psm),
            permissions: [.readable])
        let infoCharacteristic = CBMutableCharacteristic(
            type: BluetoothConstants.infoCharacteristicUUID,
            properties: [.read],
            value: info.encodedJSON(),
            permissions: [.readable])
        let newService = CBMutableService(type: BluetoothConstants.serviceUUID, primary: true)
        newService.characteristics = [psmCharacteristic, infoCharacteristic]
        service = newService
        isAddingService = true
        manager.add(newService)
    }

    private func rebuildService() {
        guard let manager, manager.state == .poweredOn else { return }
        needsServiceRebuild = false
        if manager.isAdvertising { manager.stopAdvertising() }
        if let service {
            manager.remove(service)
        }
        service = nil
        installService()
    }

    private func startAdvertising() {
        guard isRunning, let manager, manager.state == .poweredOn, service != nil, !isAddingService else { return }
        if manager.isAdvertising { manager.stopAdvertising() }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BluetoothConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: info.advertisedName
        ])
    }

    /// Forgets everything CoreBluetooth discards when it powers off or resets.
    private func resetPublishedState() {
        publishedPSM = nil
        service = nil
        isAddingService = false
        isPublishing = false
    }

    private func scheduleRetry(_ action: @escaping (BluetoothAdvertiser) -> Void) {
        cancelRetry()
        consecutiveFailures += 1
        let delay = min(Self.maxRetryDelay, pow(2, Double(min(consecutiveFailures, 6) - 1)))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            action(self)
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRetry() {
        retryWork?.cancel()
        retryWork = nil
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let newAvailability = BluetoothAvailability(peripheral.state)
        BluetoothInternals.logger.info("Peripheral manager state: \(String(describing: newAvailability), privacy: .public)")
        if peripheral.state == .poweredOn {
            publishIfNeeded()
        } else {
            cancelRetry()
            resetPublishedState()
        }
        if newAvailability != availability {
            availability = newAvailability
            onStateChange?(newAvailability)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        isPublishing = false
        if let error {
            BluetoothInternals.logger.error("Publishing the L2CAP channel failed: \(error.localizedDescription, privacy: .public)")
            if isRunning, publishedPSM == nil {
                scheduleRetry { $0.publishIfNeeded() }
            }
            return
        }
        guard isRunning, peripheral.state == .poweredOn, publishedPSM == nil else {
            // Stopped meanwhile, or a duplicate publish after a power cycle.
            if peripheral.state == .poweredOn, PSM != publishedPSM {
                peripheral.unpublishL2CAPChannel(PSM)
            }
            return
        }
        BluetoothInternals.logger.info("Published L2CAP channel on PSM \(PSM, privacy: .public)")
        publishedPSM = PSM
        installService()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didUnpublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            BluetoothInternals.logger.error("Unpublishing PSM \(PSM, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        } else {
            BluetoothInternals.logger.debug("Unpublished PSM \(PSM, privacy: .public)")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard service === self.service else { return }  // A service we already replaced.
        isAddingService = false
        if let error {
            BluetoothInternals.logger.error("Adding the GATT service failed: \(error.localizedDescription, privacy: .public)")
            self.service = nil
            if isRunning {
                scheduleRetry { $0.installService() }
            }
            return
        }
        consecutiveFailures = 0
        if needsServiceRebuild {
            rebuildService()
        } else {
            startAdvertising()
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            BluetoothInternals.logger.error("Advertising failed: \(error.localizedDescription, privacy: .public)")
            if isRunning {
                scheduleRetry { $0.startAdvertising() }
            }
        } else {
            BluetoothInternals.logger.info("Advertising Tandem service")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error {
            BluetoothInternals.logger.error("Incoming L2CAP channel failed to open: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let channel else { return }
        guard isRunning, let handler = onIncomingTransport else {
            BluetoothInternals.logger.info("Dropping incoming L2CAP channel: not accepting connections")
            return
        }
        let peer = channel.peer?.identifier.uuidString ?? "unknown central"
        guard let transport = StreamPairTransport(
            channel: channel, queue: queue,
            remoteDescription: "Bluetooth LE central \(peer) (PSM \(channel.psm))")
        else {
            BluetoothInternals.logger.error("Incoming L2CAP channel has no streams")
            return
        }
        BluetoothInternals.logger.info("Accepted L2CAP channel from \(peer, privacy: .public)")
        handler(transport)
    }
}

// Queue-confined (CoreBluetooth delegate queue).
extension BluetoothAdvertiser: @unchecked Sendable {}
