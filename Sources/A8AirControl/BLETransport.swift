import CoreBluetooth
import Foundation
import ISDTCore

struct DiscoveredCharger: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisement: Advertisement?
    var lastSeen: Date

    var modelName: String { advertisement?.modelName ?? "ISDT device" }
    var kind: ChargerKind? { advertisement?.chargerKind }
    var isSupported: Bool { kind != nil }
}

enum RadioState: Equatable {
    case unknown, poweredOn, poweredOff, unauthorized, unsupported
}

/// The one CBCentralManager shared by every charger: radio state, scanning, and routing
/// connection events to the right per-charger link.
@MainActor
final class BLECentral: NSObject {
    private(set) var radio: RadioState = .unknown
    var onRadioChange: (@MainActor (RadioState) -> Void)?
    var onDiscover: (@MainActor (DiscoveredCharger) -> Void)?

    private struct WeakLink { weak var link: BLETransport? }

    // Created in `start()` rather than `init`, so the Bluetooth permission prompt appears
    // when the app is ready for it, not at an arbitrary point.
    private var manager: CBCentralManager?
    private var known: [UUID: CBPeripheral] = [:]
    private var links: [UUID: WeakLink] = [:]

    var isReady: Bool { manager?.state == .poweredOn }

    func start() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard let manager, manager.state == .poweredOn, !manager.isScanning else { return }
        // No service filter: not every ISDT model puts the service UUID in its
        // advertisement, so match on manufacturer data in the callback instead.
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() { manager?.stopScan() }

    func register(_ link: BLETransport, for id: UUID) { links[id] = WeakLink(link: link) }

    func peripheral(for id: UUID) -> CBPeripheral? {
        known[id] ?? manager?.retrievePeripherals(withIdentifiers: [id]).first
    }

    func connect(_ peripheral: CBPeripheral) {
        known[peripheral.identifier] = peripheral
        manager?.connect(peripheral)
    }

    func cancel(_ peripheral: CBPeripheral) { manager?.cancelPeripheralConnection(peripheral) }
}

extension BLECentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: radio = .poweredOn
        case .poweredOff: radio = .poweredOff
        case .unauthorized: radio = .unauthorized
        case .unsupported: radio = .unsupported
        default: radio = .unknown
        }
        onRadioChange?(radio)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisement = Advertisement.parse(manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard advertisement != nil || services.contains(BLETransport.serviceID) else { return }

        known[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        onDiscover?(DiscoveredCharger(
            id: peripheral.identifier,
            name: name ?? advertision(advertisement),
            rssi: RSSI.intValue,
            advertisement: advertisement,
            lastSeen: Date()
        ))
    }

    private func advertision(_ ad: Advertisement?) -> String { ad?.modelName ?? "ISDT device" }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.link?.handleDidConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.link?.handleDidFailToConnect(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.link?.handleDidDisconnect(peripheral, error: error)
    }
}

/// The Bluetooth link to one charger: an async wrapper around its peripheral and the AF01/AF02
/// characteristics. Everything runs on the main queue, so delegate callbacks are main-actor
/// isolated and there's no locking to get wrong.
@MainActor
final class BLETransport: NSObject {
    enum Channel { case data, setup }

    /// Link dropped (or failed while connecting). `nil` error = we asked for it.
    var onDisconnect: (@MainActor (Error?) -> Void)?
    /// AF01 notification payloads (polling/control responses).
    var onData: (@MainActor (Data) -> Void)?
    /// AF02 notification payloads (bind + hardware info).
    var onSetupData: (@MainActor (Data) -> Void)?
    /// Connection milestones, for the diagnostics log.
    var onEvent: (@MainActor (String) -> Void)?

    static let serviceID = CBUUID(string: ISDT.serviceUUID)
    private static let dataID = CBUUID(string: ISDT.dataCharacteristicUUID)
    private static let setupID = CBUUID(string: ISDT.setupCharacteristicUUID)

    private let central: BLECentral
    let id: UUID
    private var peripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?
    private var setupCharacteristic: CBCharacteristic?

    private var pending: (id: Int, continuation: CheckedContinuation<Void, Error>)?
    private var nextOperationID = 0
    private var disconnectRequested = false

    init(central: BLECentral, id: UUID) {
        self.central = central
        self.id = id
        super.init()
        central.register(self, for: id)
    }

    var isConnected: Bool { peripheral?.state == .connected && dataCharacteristic != nil }

    // MARK: Connection

    /// Connects and discovers the AF01/AF02 characteristics.
    func connect(timeout: Double = 15) async throws {
        guard central.isReady else {
            throw ChargerError.bluetoothUnavailable("Bluetooth is not available.")
        }
        guard let target = central.peripheral(for: id) else { throw ChargerError.notConnected }
        disconnectRequested = false
        target.delegate = self
        peripheral = target
        dataCharacteristic = nil
        setupCharacteristic = nil

        do {
            onEvent?("connect() → \(target.identifier.uuidString) state=\(target.state.rawValue)")
            try await perform(timeout: timeout) { central.connect(target) }
            onEvent?("characteristics ready")
        } catch {
            central.cancel(target)
            peripheral = nil
            throw error
        }
    }

    func disconnect() {
        disconnectRequested = true
        if let peripheral { central.cancel(peripheral) }
        failPending(ChargerError.notConnected)
        clearLink()
    }

    // MARK: I/O

    func setNotify(_ enabled: Bool, on channel: Channel, timeout: Double = 5) async throws {
        guard let peripheral, let characteristic = characteristic(for: channel) else { throw ChargerError.notConnected }
        try await perform(timeout: timeout) { peripheral.setNotifyValue(enabled, for: characteristic) }
    }

    func write(_ data: Data, to channel: Channel, timeout: Double = 5) async throws {
        guard let peripheral, peripheral.state == .connected, let characteristic = characteristic(for: channel) else {
            throw ChargerError.notConnected
        }
        if characteristic.properties.contains(.writeWithoutResponse) {
            // CoreBluetooth silently drops writes made while its queue is full.
            let deadline = Date().addingTimeInterval(timeout)
            while !peripheral.canSendWriteWithoutResponse {
                guard Date() < deadline, peripheral.state == .connected else { throw ChargerError.timeout }
                try await Task.sleep(for: .milliseconds(15))
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            try await perform(timeout: timeout) { peripheral.writeValue(data, for: characteristic, type: .withResponse) }
        }
    }

    private func characteristic(for channel: Channel) -> CBCharacteristic? {
        channel == .data ? dataCharacteristic : setupCharacteristic
    }

    // MARK: One-operation-at-a-time completion plumbing

    private func perform(timeout: Double, _ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let id = nextOperationID
            nextOperationID += 1
            pending = (id, continuation)
            start()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.pending?.id == id else { return }
                self.failPending(ChargerError.timeout)
            }
        }
    }

    private func completePending() {
        guard let op = pending else { return }
        pending = nil
        op.continuation.resume()
    }

    private func failPending(_ error: Error) {
        guard let op = pending else { return }
        pending = nil
        op.continuation.resume(throwing: error)
    }

    private func clearLink() {
        peripheral = nil
        dataCharacteristic = nil
        setupCharacteristic = nil
    }

    // MARK: Events routed from BLECentral

    func handleDidConnect(_ peripheral: CBPeripheral) {
        onEvent?("didConnect; discovering services")
        peripheral.discoverServices([Self.serviceID])
    }

    func handleDidFailToConnect(_ error: Error?) {
        onEvent?("didFailToConnect: \(String(describing: error))")
        failPending(error ?? ChargerError.notConnected)
    }

    func handleDidDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        onEvent?("didDisconnect: \(String(describing: error))")
        guard peripheral === self.peripheral else { return }
        let requested = disconnectRequested
        failPending(error ?? ChargerError.notConnected)
        clearLink()
        onDisconnect?(requested ? nil : (error ?? ChargerError.notConnected))
    }
}

extension BLETransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        onEvent?("services: \(peripheral.services?.map { $0.uuid.uuidString } ?? []) error=\(String(describing: error))")
        if let error { return failPending(error) }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            return failPending(ChargerError.missingCharacteristics)
        }
        peripheral.discoverCharacteristics([Self.dataID, Self.setupID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        onEvent?("characteristics: \(service.characteristics?.map { "\($0.uuid.uuidString) props=\($0.properties.rawValue)" } ?? []) error=\(String(describing: error))")
        if let error { return failPending(error) }
        dataCharacteristic = service.characteristics?.first { $0.uuid == Self.dataID }
        setupCharacteristic = service.characteristics?.first { $0.uuid == Self.setupID }
        if dataCharacteristic != nil, setupCharacteristic != nil {
            completePending()
        } else {
            failPending(ChargerError.missingCharacteristics)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        onEvent?("notify state \(characteristic.uuid.uuidString) on=\(characteristic.isNotifying)) error=\(String(describing: error))")
        if let error { failPending(error) } else { completePending() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failPending(error) } else { completePending() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == Self.dataID {
            onData?(value)
        } else if characteristic.uuid == Self.setupID {
            onSetupData?(value)
        }
    }
}
