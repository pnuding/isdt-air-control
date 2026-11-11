import Foundation
import ISDTCore
import Observation

/// One charger: its connection, live data, settings drafts, and notifications. The app keeps one
/// of these per charger it knows; `ChargerHub` owns them and the shared Bluetooth central.
@MainActor
@Observable
final class Charger: Identifiable {
    enum Link: Equatable {
        case bluetoothUnavailable(String)
        case connecting
        /// Waiting for a button press on the charger to accept this Mac.
        case pairing
        case connected
        case retrying(String)
    }

    let id: UUID
    let kind: ChargerKind
    /// Shown in the window title and menu bar; the hub numbers duplicates ("A8 Air (2)").
    var name: String

    // MARK: Connection state

    var link: Link = .connecting
    var hardware: HardwareInfo?

    // MARK: Live data

    /// One entry per protocol channel, in display (physical) order.
    var slots: [SlotStatus]
    /// The slots to draw: all of them, except on the C4 where only the active bay layout shows.
    var visibleSlots: [Int]
    var inputMillivolts: Int?
    var inputMilliamps: Int?
    var lastUpdate: Date?

    // MARK: Settings editing

    /// What the charger reports as each slot's stored settings.
    var deviceConfigs: [Int: SlotConfig] = [:]
    /// What the user is editing per slot. Never overwritten by a sync while the slot has unapplied edits.
    var drafts: [Int: SlotConfig] = [:]
    var dirty: Set<Int> = []
    /// The slot whose settings popover is open.
    var editingSlot: Int?
    /// Slots the most recent Apply wrote to, for the result summary.
    var lastApplyTargets: [Int] = []
    var applyResults: [Int: ApplyResult] = [:]
    var isApplying = false

    // MARK: Internals

    @ObservationIgnored let transport: BLETransport
    @ObservationIgnored var session: ChargerSession?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored var detector = CompletionDetector()
    @ObservationIgnored private var c4UsesLargeBays = false
    @ObservationIgnored var isDemo = false
    @ObservationIgnored var probePath: String?
    @ObservationIgnored var probeNotes: [String] = []
    @ObservationIgnored var demoTask: Task<Void, Never>?
    @ObservationIgnored private(set) var trafficLog: [String] = []
    /// Set by the hub: a prefix for notification titles when more than one charger is known.
    @ObservationIgnored var notificationPrefix: @MainActor () -> String? = { nil }

    private static let configSyncInterval: TimeInterval = 20
    private static let maxConsecutivePollFailures = 3

    init(id: UUID, kind: ChargerKind, central: BLECentral) {
        self.id = id
        self.kind = kind
        self.name = kind.displayName
        self.slots = (0..<kind.channelCount).map { SlotStatus(slot: $0) }
        self.visibleSlots = kind == .c4Air ? ChargerKind.c4SmallBays : Array(0..<kind.channelCount)
        self.transport = BLETransport(central: central, id: id)
        transport.onDisconnect = { [weak self] _ in self?.session?.close() }
        transport.onEvent = { [weak self] text in self?.record("•", "BLE", Data(text.utf8), text: text) }
    }

    // MARK: Lifecycle

    func radioChanged(_ state: RadioState) {
        switch state {
        case .poweredOn:
            if connectionTask == nil { beginConnecting() }
        case .poweredOff:
            stopConnecting(.bluetoothUnavailable(String(localized: "Bluetooth is turned off.")))
        case .unauthorized:
            stopConnecting(.bluetoothUnavailable(String(localized: "Bluetooth access is denied. Allow it for this app in System Settings → Privacy & Security → Bluetooth.")))
        case .unsupported:
            stopConnecting(.bluetoothUnavailable(String(localized: "This Mac doesn't support Bluetooth Low Energy.")))
        case .unknown:
            break
        }
    }

    func shutdown() {
        connectionTask?.cancel()
        connectionTask = nil
        session?.close()
        transport.disconnect()
    }

    func reconnect() {
        shutdown()
        beginConnecting()
    }

    private func stopConnecting(_ link: Link) {
        shutdown()
        self.link = link
    }

    // MARK: Connection loop

    private func beginConnecting() {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in await self?.runConnectionLoop() }
    }

    /// Connects, polls until something fails, then reconnects. The charger drops
    /// the link every couple of minutes on its own, so this is the normal path.
    private func runConnectionLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            link = .connecting
            do {
                try await connectAndPoll(attempt: &attempt)
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                link = .retrying(error.localizedDescription)
            }
            session?.close()
            session = nil
            transport.disconnect()
            guard !Task.isCancelled else { break }
            attempt += 1
            try? await Task.sleep(for: .seconds(min(Double(attempt) * 2, 10)))
        }
    }

    private func connectAndPoll(attempt: inout Int) async throws {
        try await transport.connect()
        let session = ChargerSession(transport: transport, clientUUID: Pref.clientUUID(), kind: kind)
        session.onBindWaiting = { [weak self] in self?.link = .pairing }
        session.onTraffic = { [weak self] direction, channel, data in self?.record(direction, channel, data) }
        self.session = session

        hardware = try await session.open()
        link = .connected
        attempt = 0

        // The A4/C4 report each slot's settings inside every poll; the A8 needs its own query.
        if kind.usesMegaPacket { try await syncConfigs() }
        var lastConfigSync = Date()
        var failures = 0

        while !Task.isCancelled {
            do {
                apply(try await session.readSnapshot())
                failures = 0
            } catch ChargerError.timeout {
                failures += 1
                if failures >= Self.maxConsecutivePollFailures { throw ChargerError.timeout }
            }

            if kind.usesMegaPacket, !isApplying, Date().timeIntervalSince(lastConfigSync) > Self.configSyncInterval {
                try? await syncConfigs()
                lastConfigSync = Date()
            }
            let interval = UserDefaults.standard.double(forKey: Pref.pollInterval)
            try await Task.sleep(for: .seconds(min(max(interval, 1), 30)))
        }
    }

    func apply(_ snapshot: Snapshot) {
        for status in snapshot.statuses where slots.indices.contains(status.slot) { slots[status.slot] = status }
        lastUpdate = Date()
        if let mV = snapshot.inputMillivolts { inputMillivolts = mV }
        if let mA = snapshot.inputMilliamps { inputMilliamps = mA }
        if let configs = snapshot.configs { absorb(configs) }

        let visible = kind.visibleSlots(in: slots, c4UsesLargeBays: &c4UsesLargeBays)
        if visible != visibleSlots {
            visibleSlots = visible
            // A different bay layout invalidates whatever was open for the old one.
            if let editing = editingSlot, !visible.contains(editing) { editingSlot = nil }
        }
        handle(events: detector.ingest(visible.map { slots[$0] }))
    }

    /// Slow tier (A8): refresh each slot's stored settings, leaving alone any slot being edited.
    private func syncConfigs() async throws {
        guard let session else { throw ChargerError.notConnected }
        absorb(try await session.readSlotConfigs())
    }

    func absorb(_ configs: [Int: SlotConfig]) {
        for (slot, config) in configs {
            deviceConfigs[slot] = config
            if !dirty.contains(slot) { drafts[slot] = config }
        }
    }

    // MARK: Editing

    func draft(for slot: Int) -> SlotConfig {
        drafts[slot] ?? deviceConfigs[slot] ?? .defaults(for: .liIon)
    }

    /// The config the popover edits: the draft of the slot being edited.
    var editorConfig: SlotConfig {
        get { editingSlot.map(draft(for:)) ?? .defaults(for: .liIon) }
        set {
            guard let slot = editingSlot, newValue != draft(for: slot) else { return }
            drafts[slot] = newValue
            dirty.insert(slot)
            applyResults.removeAll()
            lastApplyTargets = []
        }
    }

    var editorIsDirty: Bool { editingSlot.map(dirty.contains) ?? false }

    /// Discard unapplied edits and go back to what the charger has stored.
    func revertEditor() {
        guard let slot = editingSlot else { return }
        drafts[slot] = deviceConfigs[slot] ?? .defaults(for: .liIon)
        dirty.remove(slot)
        applyResults.removeAll()
        lastApplyTargets = []
    }

    // MARK: Applying

    var canApply: Bool {
        link == .connected && editingSlot != nil && editorConfig.isValid(currentRange: kind.currentRange) && !isApplying
    }

    /// Writes the edited slot's settings to that slot, or (`toAll`) to every visible slot, then reads them back to confirm.
    func applyEditor(toAll: Bool = false) async {
        guard canApply, let editing = editingSlot else { return }
        let targets = toAll ? visibleSlots : [editing]
        let config = editorConfig
        if isDemo {
            await applyDemo(targets: targets, config: config)
            return
        }
        guard let session else { return }

        isApplying = true
        defer { isApplying = false }
        lastApplyTargets = targets
        applyResults.removeAll()
        for slot in targets { applyResults[slot] = .pending }

        var failures: [Int: String] = [:]
        var unacknowledged: Set<Int> = []
        for slot in targets {
            do {
                if try await session.writeSlot(slot, config: config) == .unacknowledged { unacknowledged.insert(slot) }
            } catch {
                failures[slot] = error.localizedDescription
            }
            // The chargers drop commands that arrive back-to-back.
            try? await Task.sleep(for: .milliseconds(300))
        }

        try? await Task.sleep(for: .seconds(1))
        let readback = try? await session.readSlotConfigs(slots: targets)

        for slot in targets {
            if let message = failures[slot] {
                applyResults[slot] = .failed(message)
                continue
            }
            if let stored = readback?[slot] {
                deviceConfigs[slot] = stored
                drafts[slot] = stored
                dirty.remove(slot)
                applyResults[slot] = stored.matches(config) ? .verified : .adjusted(stored)
            } else {
                applyResults[slot] = .unconfirmed
                if !unacknowledged.contains(slot) { dirty.remove(slot) }
            }
        }
        if let readback { absorb(readback) }
    }

    // MARK: Notifications

    func handle(events: [ChargeEvent]) {
        guard !events.isEmpty else { return }
        let defaults = UserDefaults.standard
        let sound = defaults.bool(forKey: Pref.notificationSound)
        let prefix = notificationPrefix()

        func title(_ text: String) -> String { prefix.map { "\($0) · \(text)" } ?? text }

        let finished = events.compactMap { if case .finished(let s) = $0 { s } else { nil } }
        if !finished.isEmpty, defaults.bool(forKey: Pref.notifyOnDone) {
            let message = ChargeMessages.completion(finished: finished, slots: slots)
            Task { await NotificationManager.shared.post(title: title(message.title), body: message.body, identifier: "done-\(UUID().uuidString)", playSound: sound) }
        }

        let failed = events.compactMap { if case .failed(let s) = $0 { s } else { nil } }
        if !failed.isEmpty, defaults.bool(forKey: Pref.notifyOnError) {
            let message = ChargeMessages.error(failed: failed, slots: slots)
            Task { await NotificationManager.shared.post(title: title(message.title), body: message.body, identifier: "error-\(UUID().uuidString)", playSound: sound) }
        }
    }

    // MARK: Derived

    var visibleStatuses: [SlotStatus] { visibleSlots.map { slots[$0] } }
    var chargingCount: Int { visibleStatuses.filter { $0.phase.isCharging }.count }
    var doneCount: Int { visibleStatuses.filter { $0.phase == .done }.count }
    var inputWatts: Double? {
        guard let mV = inputMillivolts, let mA = inputMilliamps else { return nil }
        return Double(mV) * Double(mA) / 1_000_000
    }

    // MARK: Diagnostics

    func record(_ direction: String, _ channel: String, _ data: Data, text: String? = nil) {
        guard probePath != nil || UserDefaults.standard.bool(forKey: Pref.trafficLogging) else { return }
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        trafficLog.append(text.map { "\(stamp) \(direction) \(channel) \($0)" } ?? "\(stamp) \(direction) \(channel) [\(data.count)] \(hex)")
        if trafficLog.count > 500 { trafficLog.removeFirst(trafficLog.count - 500) }
    }
}
