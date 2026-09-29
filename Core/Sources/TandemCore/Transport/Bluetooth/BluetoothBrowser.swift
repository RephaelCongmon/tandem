import CoreBluetooth
import Foundation
import os

/// Studio-side Bluetooth LE fallback: finds nearby Source Macs advertising the Tandem
/// service and opens L2CAP channels to them.
///
/// Discovery: while scanning, every newly seen peripheral is briefly connected to read its
/// PSM and `BluetoothPeerInfo` characteristics; the values are cached per peripheral and the
/// GATT connection is dropped again to save radio time. `discoveries` lists each Source
/// (deduplicated by `info.id`, since a Mac's Bluetooth address, and so its peripheral
/// identifier, rotates) with fresh RSSI/`lastSeen` values, and drops entries not seen for
/// about 30 seconds. RSSI-only updates are throttled to one callback every ~2 seconds.
///
/// Connecting: `connect(toDeviceID:timeout:completion:)` connects the peripheral if needed,
/// opens the cached PSM and, if that fails (for instance because the Source restarted and
/// published a new PSM), re-reads the characteristics once and retries. The GATT connection
/// is kept up for as long as the resulting transport is open, because the L2CAP channel
/// dies with it.
///
/// Threading: create and use on `queue`. The `CBCentralManager` runs on `queue`, and every
/// callback (including the transports it creates) is delivered there.
public final class BluetoothBrowser: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// A Source Mac seen nearby.
    public struct Discovery: Hashable, Sendable {
        /// CoreBluetooth's identifier for the peripheral (changes when the Source's
        /// Bluetooth address rotates; use `info.id` to recognise a Mac).
        public let peripheralID: UUID
        /// The identity read from the Source's info characteristic.
        public let info: BluetoothPeerInfo
        /// Latest advertisement signal strength in dBm (closer to 0 is stronger).
        public let rssi: Int
        /// When the Source's advertisement was last received.
        public let lastSeen: Date

        /// Creates a discovery record.
        public init(peripheralID: UUID, info: BluetoothPeerInfo, rssi: Int, lastSeen: Date) {
            self.peripheralID = peripheralID
            self.info = info
            self.rssi = rssi
            self.lastSeen = lastSeen
        }
    }

    /// Entries not seen for longer than this are dropped.
    static let staleInterval: TimeInterval = 30
    /// How often stale entries are swept.
    static let sweepInterval: TimeInterval = 5
    /// Minimum spacing of RSSI/`lastSeen`-only `onDiscoveriesChanged` callbacks.
    static let refreshInterval: TimeInterval = 2
    /// Budget for connecting to a new peripheral and reading its characteristics.
    static let probeTimeout: TimeInterval = 10
    /// Longest back-off before re-probing a peripheral whose probe failed.
    static let maxProbeBackoff: TimeInterval = 60

    /// The queue all methods must be called on and all callbacks are delivered on.
    public let queue: DispatchQueue

    /// Called on `queue` when `discoveries` changes.
    public var onDiscoveriesChanged: (([Discovery]) -> Void)?

    /// Called on `queue` whenever `availability` changes.
    public var onStateChange: ((BluetoothAvailability) -> Void)?

    /// The latest Bluetooth availability reported by CoreBluetooth.
    public private(set) var availability: BluetoothAvailability = .unknown

    /// Nearby Sources, sorted by name. Updated before `onDiscoveriesChanged` fires.
    public private(set) var discoveries: [Discovery] = []

    /// Whether `startScanning()` has been called without a matching `stopScanning()`.
    public private(set) var isScanning = false

    private var central: CBCentralManager?
    private var records: [UUID: PeerRecord] = [:]
    private var attempts: [ConnectAttempt] = []
    private var isScanActive = false
    private var sweepTimer: DispatchSourceTimer?
    private var pendingPublish: DispatchWorkItem?

    /// Creates an idle browser. Nothing touches Bluetooth until `startScanning()` or
    /// `connect(toDeviceID:timeout:completion:)`.
    ///
    /// - Parameter queue: Serial queue for the central manager, all calls and all callbacks.
    public init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    deinit {
        sweepTimer?.cancel()
        pendingPublish?.cancel()
    }

    // MARK: - Public API

    /// Starts scanning for Sources (as soon as Bluetooth is powered on). Idempotent.
    public func startScanning() {
        BluetoothInternals.assertOnQueue(queue)
        isScanning = true
        ensureCentral()
        updateScanning()
    }

    /// Stops scanning. Existing entries age out of `discoveries` after ~30 seconds; pending
    /// connection attempts keep scanning until they finish. Idempotent.
    public func stopScanning() {
        BluetoothInternals.assertOnQueue(queue)
        isScanning = false
        updateScanning()
    }

    /// Opens an L2CAP channel to the Source whose `BluetoothPeerInfo.id` is `id`.
    ///
    /// If that Source hasn't been discovered yet, the browser scans for it until `timeout`.
    /// `completion` fires exactly once on `queue` with an unstarted transport (install
    /// callbacks, then call `start()`), or with `.timedOut`, `.unavailable` (Bluetooth off,
    /// unauthorized or unsupported), `.connectionFailed` or `.connectionLost`.
    public func connect(
        toDeviceID id: String,
        timeout: TimeInterval = 12,
        completion: @escaping (Result<StreamPairTransport, TransportError>) -> Void
    ) {
        BluetoothInternals.assertOnQueue(queue)
        let central = ensureCentral()
        switch central.state {
        case .poweredOff, .unauthorized, .unsupported:
            let error = TransportError.unavailable(BluetoothAvailability(central.state).localizedDescription)
            queue.async { completion(.failure(error)) }
            return
        default:
            break
        }

        let attempt = ConnectAttempt(deviceID: id, completion: completion)
        attempts.append(attempt)
        let timeoutWork = DispatchWorkItem { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            BluetoothInternals.logger.error("Bluetooth connection to \(attempt.deviceID, privacy: .public) timed out in phase \(String(describing: attempt.phase), privacy: .public)")
            self.finish(attempt, .failure(.timedOut))
        }
        attempt.timeoutWork = timeoutWork
        queue.asyncAfter(deadline: .now() + max(0, timeout), execute: timeoutWork)

        if central.state == .poweredOn, let record = bestRecord(forDeviceID: id) {
            begin(attempt, with: record)
        } else {
            attempt.phase = .waitingForPeer
            updateScanning()
        }
    }

    // MARK: - Scanning & discoveries

    @discardableResult
    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        let manager = CBCentralManager(
            delegate: self, queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        central = manager
        return manager
    }

    private func updateScanning() {
        guard let central else { return }
        let needed = isScanning || attempts.contains { $0.phase == .waitingForPeer }
        if needed, central.state == .poweredOn {
            if !isScanActive {
                isScanActive = true
                central.scanForPeripherals(
                    withServices: [BluetoothConstants.serviceUUID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                BluetoothInternals.logger.info("Scanning for Tandem Sources")
            }
        } else if isScanActive {
            isScanActive = false
            if central.state == .poweredOn { central.stopScan() }
            BluetoothInternals.logger.info("Stopped scanning")
        }
        updateSweepTimer()
    }

    private func updateSweepTimer() {
        let needed = isScanActive || !records.isEmpty || !discoveries.isEmpty
        if needed, sweepTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sweep() }
            timer.resume()
            sweepTimer = timer
        } else if !needed, let timer = sweepTimer {
            timer.cancel()
            sweepTimer = nil
        }
    }

    private func sweep() {
        let now = Date()
        for (identifier, record) in records
        where now.timeIntervalSince(record.lastSeen) > Self.staleInterval && !isInUse(record) {
            records[identifier] = nil
            disconnect(record)
        }
        publishDiscoveries()
        updateSweepTimer()
    }

    private func bestRecord(forDeviceID id: String) -> PeerRecord? {
        records.values
            .filter { $0.info?.id == id && $0.psm != nil }
            .max { $0.lastSeen < $1.lastSeen }
    }

    private func setNeedsPublish(immediately: Bool) {
        if immediately {
            publishDiscoveries()
            return
        }
        guard pendingPublish == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPublish = nil
            self.publishDiscoveries()
        }
        pendingPublish = work
        queue.asyncAfter(deadline: .now() + Self.refreshInterval, execute: work)
    }

    private func publishDiscoveries() {
        pendingPublish?.cancel()
        pendingPublish = nil
        let now = Date()
        var newest: [String: Discovery] = [:]
        for record in records.values {
            guard let info = record.info, now.timeIntervalSince(record.lastSeen) <= Self.staleInterval else { continue }
            if let existing = newest[info.id], existing.lastSeen >= record.lastSeen { continue }
            newest[info.id] = Discovery(
                peripheralID: record.peripheral.identifier, info: info,
                rssi: record.rssi, lastSeen: record.lastSeen)
        }
        let sorted = newest.values.sorted { lhs, rhs in
            let order = lhs.info.name.localizedStandardCompare(rhs.info.name)
            return order == .orderedSame ? lhs.info.id < rhs.info.id : order == .orderedAscending
        }
        guard sorted != discoveries else { return }
        discoveries = sorted
        onDiscoveriesChanged?(sorted)
    }

    // MARK: - Probing (connect, read PSM + info, disconnect)

    private func probeIfNeeded(_ record: PeerRecord) {
        guard record.info == nil || record.needsRefresh else { return }
        guard !record.isProbing, Date() >= record.nextProbeDate else { return }
        guard let central, central.state == .poweredOn else { return }
        record.isProbing = true
        record.needsRefresh = false
        let timeout = DispatchWorkItem { [weak self, weak record] in
            guard let self, let record else { return }
            BluetoothInternals.logger.error("Probing peripheral \(record.peripheral.identifier, privacy: .public) timed out")
            self.finishProbe(record, succeeded: false)
        }
        record.probeTimeout = timeout
        queue.asyncAfter(deadline: .now() + Self.probeTimeout, execute: timeout)
        BluetoothInternals.logger.debug("Probing peripheral \(record.peripheral.identifier, privacy: .public)")
        if record.peripheral.state == .connected {
            loadCharacteristics(record)
        } else {
            central.connect(record.peripheral, options: nil)
        }
    }

    private func finishProbe(_ record: PeerRecord, succeeded: Bool) {
        guard record.isProbing else { return }
        record.isProbing = false
        record.probeTimeout?.cancel()
        record.probeTimeout = nil
        if succeeded {
            record.probeFailures = 0
            record.nextProbeDate = .distantPast
        } else {
            record.probeFailures += 1
            let backoff = min(Self.maxProbeBackoff, 5 * pow(2, Double(min(record.probeFailures, 6) - 1)))
            record.nextProbeDate = Date().addingTimeInterval(backoff)
        }
        releaseConnectionIfIdle(record)
    }

    /// Discovers the service and reads both characteristics on a connected peripheral.
    /// Completion is reported through `loadFinished(_:_:)`.
    private func loadCharacteristics(_ record: PeerRecord) {
        guard !record.isLoading else { return }
        record.isLoading = true
        record.pendingReads = []
        record.loadedPSM = nil
        record.loadedInfo = nil
        record.peripheral.discoverServices([BluetoothConstants.serviceUUID])
    }

    private func loadFinished(_ record: PeerRecord, _ outcome: Result<(CBL2CAPPSM, BluetoothPeerInfo), TransportError>) {
        guard record.isLoading else { return }
        record.isLoading = false
        record.pendingReads = []
        record.loadedPSM = nil
        record.loadedInfo = nil

        switch outcome {
        case .success(let (psm, info)):
            let infoChanged = record.info != info
            record.psm = psm
            record.info = info
            BluetoothInternals.logger.info("Read Tandem Source \(info.name, privacy: .private) (PSM \(psm, privacy: .public)) on peripheral \(record.peripheral.identifier, privacy: .public)")
            // Advance attempts before the probe releases the connection.
            for attempt in attempts where attempt.record === record && attempt.phase == .loading {
                openChannel(attempt)
            }
            for attempt in attempts where attempt.phase == .waitingForPeer && attempt.deviceID == info.id {
                begin(attempt, with: record)
            }
            finishProbe(record, succeeded: true)
            if infoChanged { setNeedsPublish(immediately: true) }
            updateScanning()
        case .failure(let error):
            BluetoothInternals.logger.error("Reading Tandem characteristics failed: \(error.localizedDescription, privacy: .public)")
            for attempt in attempts where attempt.record === record && attempt.phase == .loading {
                finish(attempt, .failure(error))
            }
            finishProbe(record, succeeded: false)
        }
    }

    // MARK: - Connecting

    private func begin(_ attempt: ConnectAttempt, with record: PeerRecord) {
        guard !attempt.isFinished else { return }
        attempt.record = record
        attempt.phase = .connecting
        updateScanning()
        if record.peripheral.state == .connected {
            advanceConnected(attempt)
        } else {
            central?.connect(record.peripheral, options: nil)
        }
    }

    private func advanceConnected(_ attempt: ConnectAttempt) {
        guard !attempt.isFinished, let record = attempt.record else { return }
        if record.psm == nil {
            attempt.phase = .loading
            loadCharacteristics(record)
        } else {
            openChannel(attempt)
        }
    }

    private func openChannel(_ attempt: ConnectAttempt) {
        guard !attempt.isFinished, let record = attempt.record else { return }
        guard let psm = record.psm else {
            advanceConnected(attempt)
            return
        }
        guard record.peripheral.state == .connected else {
            attempt.phase = .connecting
            central?.connect(record.peripheral, options: nil)
            return
        }
        attempt.phase = .opening
        BluetoothInternals.logger.info("Opening L2CAP PSM \(psm, privacy: .public) on \(record.peripheral.identifier, privacy: .public)")
        record.peripheral.openL2CAPChannel(psm)
    }

    private func finish(_ attempt: ConnectAttempt, _ result: Result<StreamPairTransport, TransportError>) {
        guard !attempt.isFinished else { return }
        attempt.isFinished = true
        attempt.phase = .finished
        attempt.timeoutWork?.cancel()
        attempt.timeoutWork = nil
        attempts.removeAll { $0 === attempt }
        if let record = attempt.record { releaseConnectionIfIdle(record) }
        updateScanning()
        attempt.completion(result)
    }

    private func isInUse(_ record: PeerRecord) -> Bool {
        record.isProbing || record.activeTransports > 0 || attempts.contains { $0.record === record }
    }

    private func releaseConnectionIfIdle(_ record: PeerRecord) {
        guard !isInUse(record) else { return }
        disconnect(record)
    }

    private func disconnect(_ record: PeerRecord) {
        record.isLoading = false
        record.pendingReads = []
        guard let central, central.state == .poweredOn else { return }
        switch record.peripheral.state {
        case .connected, .connecting:
            central.cancelPeripheralConnection(record.peripheral)
        default:
            break
        }
    }

    private func transportEnded(for record: PeerRecord) {
        record.activeTransports = max(0, record.activeTransports - 1)
        releaseConnectionIfIdle(record)
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newAvailability = BluetoothAvailability(central.state)
        BluetoothInternals.logger.info("Central manager state: \(String(describing: newAvailability), privacy: .public)")
        if newAvailability != availability {
            availability = newAvailability
            onStateChange?(newAvailability)
        }
        switch central.state {
        case .poweredOn:
            updateScanning()
        case .unknown:
            break
        default:
            // CoreBluetooth invalidates scans, connections and peripherals.
            isScanActive = false
            for record in records.values {
                record.probeTimeout?.cancel()
                record.probeTimeout = nil
            }
            records.removeAll()
            let error = TransportError.unavailable(
                newAvailability == .unknown
                    ? "Bluetooth was interrupted."
                    : newAvailability.localizedDescription)
            for attempt in attempts {
                finish(attempt, .failure(error))
            }
            publishDiscoveries()
            updateSweepTimer()
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let now = Date()
        let record: PeerRecord
        if let existing = records[peripheral.identifier] {
            record = existing
        } else {
            record = PeerRecord(peripheral: peripheral, lastSeen: now)
            peripheral.delegate = self
            records[peripheral.identifier] = record
            updateSweepTimer()
        }
        let rssi = RSSI.intValue
        if rssi < 0 { record.rssi = rssi }  // 127 means "not available".
        record.lastSeen = now
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            if let previous = record.advertisedName, previous != name, record.info != nil {
                record.needsRefresh = true  // The Source renamed itself; re-read its info.
            }
            record.advertisedName = name
        }
        probeIfNeeded(record)
        if let info = record.info {
            let listed = discoveries.contains { $0.info.id == info.id }
            setNeedsPublish(immediately: !listed)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let record = records[peripheral.identifier] else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        record.lastSeen = Date()
        let waiting = attempts.filter { $0.record === record && $0.phase == .connecting }
        if record.isProbing { loadCharacteristics(record) }
        for attempt in waiting { advanceConnected(attempt) }
        releaseConnectionIfIdle(record)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let record = records[peripheral.identifier] else { return }
        record.isLoading = false
        record.pendingReads = []
        let reason = error?.localizedDescription ?? "The Mac couldn't be reached over Bluetooth."
        BluetoothInternals.logger.error("Connecting to \(peripheral.identifier, privacy: .public) failed: \(reason, privacy: .public)")
        for attempt in attempts where attempt.record === record {
            finish(attempt, .failure(.connectionFailed(reason)))
        }
        finishProbe(record, succeeded: false)
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard let record = records[peripheral.identifier] else { return }
        record.isLoading = false
        record.pendingReads = []
        if let error {
            BluetoothInternals.logger.info("Peripheral \(peripheral.identifier, privacy: .public) disconnected: \(error.localizedDescription, privacy: .public)")
        }
        for attempt in attempts where attempt.record === record {
            switch attempt.phase {
            case .connecting:
                // Usually the tail of our own probe disconnect; connect again.
                central.connect(peripheral, options: nil)
            case .loading, .opening:
                finish(attempt, .failure(.connectionLost("The Bluetooth connection dropped.")))
            case .waitingForPeer, .finished:
                break
            }
        }
        finishProbe(record, succeeded: false)
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let record = records[peripheral.identifier], record.isLoading else { return }
        if let error {
            loadFinished(record, .failure(.connectionFailed("Service discovery failed: \(error.localizedDescription)")))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BluetoothConstants.serviceUUID }) else {
            loadFinished(record, .failure(.connectionFailed("The Mac isn't offering a Tandem connection.")))
            return
        }
        peripheral.discoverCharacteristics(
            [BluetoothConstants.psmCharacteristicUUID, BluetoothConstants.infoCharacteristicUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let record = records[peripheral.identifier], record.isLoading,
              service.uuid == BluetoothConstants.serviceUUID
        else { return }
        if let error {
            loadFinished(record, .failure(.connectionFailed("Characteristic discovery failed: \(error.localizedDescription)")))
            return
        }
        let characteristics = service.characteristics ?? []
        guard
            let psmCharacteristic = characteristics.first(where: { $0.uuid == BluetoothConstants.psmCharacteristicUUID }),
            let infoCharacteristic = characteristics.first(where: { $0.uuid == BluetoothConstants.infoCharacteristicUUID })
        else {
            loadFinished(record, .failure(.protocolViolation("The Tandem service is missing characteristics.")))
            return
        }
        record.pendingReads = [psmCharacteristic.uuid, infoCharacteristic.uuid]
        peripheral.readValue(for: psmCharacteristic)
        peripheral.readValue(for: infoCharacteristic)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let record = records[peripheral.identifier], record.isLoading,
              record.pendingReads.contains(characteristic.uuid)
        else { return }
        if let error {
            loadFinished(record, .failure(.connectionFailed("Reading a characteristic failed: \(error.localizedDescription)")))
            return
        }
        let value = characteristic.value ?? Data()
        switch characteristic.uuid {
        case BluetoothConstants.psmCharacteristicUUID:
            guard let psm = BluetoothConstants.decodePSM(value) else {
                loadFinished(record, .failure(.protocolViolation("The Source published an invalid PSM.")))
                return
            }
            record.loadedPSM = psm
        case BluetoothConstants.infoCharacteristicUUID:
            guard let info = try? BluetoothPeerInfo.decode(from: value) else {
                loadFinished(record, .failure(.protocolViolation("The Source published invalid device info.")))
                return
            }
            record.loadedInfo = info
        default:
            return
        }
        record.pendingReads.remove(characteristic.uuid)
        if record.pendingReads.isEmpty, let psm = record.loadedPSM, let info = record.loadedInfo {
            loadFinished(record, .success((psm, info)))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard let record = records[peripheral.identifier],
              invalidatedServices.contains(where: { $0.uuid == BluetoothConstants.serviceUUID })
        else { return }
        // The Source rebuilt its service (new info or PSM); re-read on the next sighting.
        record.needsRefresh = true
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let attempt = attempts.first(where: { $0.phase == .opening && $0.record?.peripheral === peripheral }),
              let record = attempt.record
        else {
            BluetoothInternals.logger.info("Dropping an L2CAP channel nobody is waiting for")
            return
        }
        guard let channel, error == nil else {
            let reason = error?.localizedDescription ?? "The Bluetooth channel couldn't be opened."
            if !attempt.didRefreshCharacteristics {
                // The Source may have restarted with a new PSM: re-read it once and retry.
                BluetoothInternals.logger.info("Opening L2CAP channel failed (\(reason, privacy: .public)); re-reading the PSM")
                attempt.didRefreshCharacteristics = true
                attempt.phase = .loading
                record.psm = nil
                loadCharacteristics(record)
            } else {
                finish(attempt, .failure(.connectionFailed(reason)))
            }
            return
        }
        let name = record.info?.name ?? "Source"
        guard let transport = StreamPairTransport(
            channel: channel, queue: queue,
            remoteDescription: "\(name) via Bluetooth LE (PSM \(channel.psm))")
        else {
            finish(attempt, .failure(.connectionFailed("The Bluetooth channel has no streams.")))
            return
        }
        record.activeTransports += 1
        transport.terminationObserver = { [weak self, weak record] in
            guard let self, let record else { return }
            self.transportEnded(for: record)
        }
        BluetoothInternals.logger.info("Opened L2CAP channel to \(name, privacy: .private)")
        finish(attempt, .success(transport))
    }
}

// MARK: - Internal bookkeeping

/// What the browser knows about one peripheral. Holds the `CBPeripheral` strongly.
private final class PeerRecord {
    let peripheral: CBPeripheral
    var rssi = -127
    var lastSeen: Date
    var advertisedName: String?

    /// Cached characteristic values.
    var psm: CBL2CAPPSM?
    var info: BluetoothPeerInfo?

    /// Probe (connect → read → disconnect) bookkeeping.
    var isProbing = false
    var needsRefresh = false
    var probeFailures = 0
    var nextProbeDate = Date.distantPast
    var probeTimeout: DispatchWorkItem?

    /// In-flight characteristic load.
    var isLoading = false
    var pendingReads: Set<CBUUID> = []
    var loadedPSM: CBL2CAPPSM?
    var loadedInfo: BluetoothPeerInfo?

    /// Open transports riding on this peripheral's connection.
    var activeTransports = 0

    init(peripheral: CBPeripheral, lastSeen: Date) {
        self.peripheral = peripheral
        self.lastSeen = lastSeen
    }
}

/// One `connect(toDeviceID:)` call.
private final class ConnectAttempt {
    enum Phase: Equatable {
        case waitingForPeer
        case connecting
        case loading
        case opening
        case finished
    }

    let deviceID: String
    let completion: (Result<StreamPairTransport, TransportError>) -> Void
    var phase: Phase = .waitingForPeer
    var record: PeerRecord?
    var didRefreshCharacteristics = false
    var timeoutWork: DispatchWorkItem?
    var isFinished = false

    init(deviceID: String, completion: @escaping (Result<StreamPairTransport, TransportError>) -> Void) {
        self.deviceID = deviceID
        self.completion = completion
    }
}
