import Foundation
import ISDTCore
import Observation

/// App-level state: the shared Bluetooth central, every charger the app knows, and what's
/// currently in range. Each charger gets its own window.
@MainActor
@Observable
final class ChargerHub {
    let central = BLECentral()

    var chargers: [Charger] = []
    var radio: RadioState = .unknown
    /// Everything advertising nearby (including chargers already added; use `nearby` for the picker).
    private(set) var discovered: [DiscoveredCharger] = []
    /// Chargers whose window the UI should open. Drained by the menu bar item, which is always alive.
    var windowRequests: [UUID] = []
    /// Bumped to ask the UI to open the Chargers window.
    var chargersWindowRequests = 0

    @ObservationIgnored var isDemo = false
    @ObservationIgnored private var scanUsers = 0
    @ObservationIgnored private var autoAddTask: Task<Void, Never>?

    init() {
        Pref.registerDefaults()
        let saved = Self.loadSaved()
        for entry in saved { adopt(Charger(id: entry.id, kind: entry.kind, central: central), persist: false) }
    }

    // MARK: Lifecycle

    func start() {
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            startDemo()
            return
        }
        central.onRadioChange = { [weak self] state in self?.radioChanged(state) }
        central.onDiscover = { [weak self] device in self?.deviceDiscovered(device) }
        central.start()

        // Every known charger gets its window at launch; it shows "Connecting…" until the link is up.
        windowRequests.append(contentsOf: chargers.map(\.id))
        if chargers.isEmpty { chargersWindowRequests += 1 }
        startProbesIfRequested()

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Pref.notifyOnDone) || defaults.bool(forKey: Pref.notifyOnError) {
            Task { await NotificationManager.shared.requestAuthorization() }
        }
    }

    func shutdown() {
        chargers.forEach { $0.shutdown() }
    }

    private func radioChanged(_ state: RadioState) {
        radio = state
        chargers.forEach { $0.radioChanged(state) }
        updateScanning()
    }

    // MARK: Chargers

    func charger(id: UUID) -> Charger? { chargers.first { $0.id == id } }

    /// Chargers in range that haven't been added yet.
    var nearby: [DiscoveredCharger] {
        discovered.filter { device in !chargers.contains { $0.id == device.id } }
    }

    func add(_ device: DiscoveredCharger) {
        guard let kind = device.kind, charger(id: device.id) == nil else { return }
        let charger = Charger(id: device.id, kind: kind, central: central)
        adopt(charger, persist: true)
        charger.radioChanged(radio)
        windowRequests.append(charger.id)
    }

    func forget(_ charger: Charger) {
        charger.shutdown()
        chargers.removeAll { $0.id == charger.id }
        renumber()
        persist()
        updateScanning()
    }

    func adopt(_ charger: Charger, persist shouldPersist: Bool) {
        charger.notificationPrefix = { [weak self, weak charger] in
            guard let self, let charger, self.chargers.count > 1 else { return nil }
            return charger.name
        }
        chargers.append(charger)
        renumber()
        if shouldPersist { persist() }
        updateScanning()
    }

    /// Two A8s are "A8 Air (1)" and "A8 Air (2)"; a lone one is just "A8 Air".
    private func renumber() {
        for kind in ChargerKind.allCases {
            let same = chargers.filter { $0.kind == kind }
            for (index, charger) in same.enumerated() {
                charger.name = same.count > 1 ? "\(kind.displayName) (\(index + 1))" : kind.displayName
            }
        }
    }

    var chargingCount: Int { chargers.reduce(0) { $0 + $1.chargingCount } }
    var doneCount: Int { chargers.reduce(0) { $0 + $1.doneCount } }

    // MARK: Discovery

    /// The Chargers window calls these while it's open. With no chargers at all we scan regardless.
    func beginScanning() { scanUsers += 1; updateScanning() }
    func endScanning() { scanUsers = max(scanUsers - 1, 0); updateScanning() }

    private func updateScanning() {
        guard !isDemo else { return }
        if radio == .poweredOn, scanUsers > 0 || chargers.isEmpty {
            central.startScan()
        } else {
            central.stopScan()
        }
    }

    private func deviceDiscovered(_ device: DiscoveredCharger) {
        discovered.removeAll { $0.id == device.id || Date().timeIntervalSince($0.lastSeen) > 20 }
        discovered.append(device)
        discovered.sort { $0.rssi > $1.rssi }
        autoAddIfUnambiguous()
    }

    /// First run, exactly one supported charger in range: just add it.
    private func autoAddIfUnambiguous() {
        guard chargers.isEmpty, autoAddTask == nil else { return }
        autoAddTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            autoAddTask = nil
            let candidates = nearby.filter(\.isSupported)
            if chargers.isEmpty, candidates.count == 1, let only = candidates.first { add(only) }
        }
    }

    // MARK: Persistence

    private func persist() {
        let saved = chargers.map { SavedCharger(id: $0.id, kind: $0.kind) }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Pref.chargers)
    }

    private static func loadSaved() -> [SavedCharger] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Pref.chargers), let saved = try? JSONDecoder().decode([SavedCharger].self, from: data) {
            return saved
        }
        // Migrate the single charger of earlier versions (the A8 was the only supported model).
        if let id = defaults.string(forKey: Pref.legacyDeviceID).flatMap(UUID.init) {
            let saved = [SavedCharger(id: id, kind: .a8Air)]
            defaults.set(try? JSONEncoder().encode(saved), forKey: Pref.chargers)
            defaults.removeObject(forKey: Pref.legacyDeviceID)
            defaults.removeObject(forKey: Pref.legacyDeviceName)
            return saved
        }
        return []
    }
}
