import Foundation
import ISDTCore

/// Everything one poll cycle learns about a charger, in display-slot order.
struct Snapshot {
    var statuses: [SlotStatus]
    /// Stored settings per display slot, when the poll got them for free (A4/C4 report them inside
    /// every WorkState reply). The A8 needs a separate settings query instead.
    var configs: [Int: SlotConfig]?
    var inputMillivolts: Int?
    var inputMilliamps: Int?
}

/// The ISDT charger protocol on top of `BLETransport`: handshake, typed requests, and settings
/// writes. One instance per connection attempt.
@MainActor
final class ChargerSession {
    enum WriteOutcome { case acknowledged, unacknowledged }

    let kind: ChargerKind

    private let transport: BLETransport
    private let clientUUID: Data
    private let frames = ResponseRouter<Frame>()
    private let setupMessages = ResponseRouter<Data>()
    private let lock = AsyncLock()
    private var assembler: FrameAssembler

    /// The charger beeped and wants a button pressed to accept this client.
    var onBindWaiting: (@MainActor () -> Void)?
    /// Raw traffic for the diagnostics log: ("→" / "←", channel, bytes).
    var onTraffic: (@MainActor (String, String, Data) -> Void)?

    init(transport: BLETransport, clientUUID: Data, kind: ChargerKind) {
        self.transport = transport
        self.clientUUID = clientUUID
        self.kind = kind
        self.assembler = FrameAssembler(kind: kind)
        transport.onData = { [weak self] data in self?.receive(data) }
        transport.onSetupData = { [weak self] data in self?.receiveSetup(data) }
    }

    // MARK: Handshake

    /// Subscribes, binds, and reads hardware info. Hardware info failing is not fatal.
    func open() async throws -> HardwareInfo? {
        try await transport.setNotify(true, on: .data)
        // The charger needs a moment after subscribing before it takes the bind.
        try await Task.sleep(for: .seconds(1.0))

        try await transport.setNotify(true, on: .setup)
        try await Task.sleep(for: .milliseconds(300))
        defer { Task { [transport] in try? await transport.setNotify(false, on: .setup) } }

        try await bind()
        return try? await readHardwareInfo()
    }

    private func bind() async throws {
        let command = Command.bind(clientUUID: clientUUID)
        do {
            // Known client: answers at once. New client: beeps, then answers
            // after a button press, so allow time for a human.
            _ = try await setupMessages.wait(
                timeout: 30,
                match: { FrameParser.parseBindResult($0) == 0 },
                send: { [self] in try await writeSetup(command) }
            )
        } catch ChargerError.timeout {
            throw ChargerError.pairingTimedOut
        }
    }

    private func readHardwareInfo() async throws -> HardwareInfo {
        let reply = try await setupMessages.wait(
            timeout: 5,
            match: { FrameParser.parseHardwareInfo($0) != nil },
            send: { [self] in try await writeSetup(Command.hardwareInfo) }
        )
        guard let info = FrameParser.parseHardwareInfo(reply) else { throw ChargerError.timeout }
        return info
    }

    func close() {
        frames.failAll(ChargerError.notConnected)
        setupMessages.failAll(ChargerError.notConnected)
        assembler.reset()
        transport.onData = nil
        transport.onSetupData = nil
    }

    // MARK: Reads

    /// One full poll: slot statuses (display order) plus the charger's input voltage/current.
    func readSnapshot() async throws -> Snapshot {
        kind.usesMegaPacket ? try await readMegaSnapshot() : try await readChannelSnapshot()
    }

    /// A8: one request returns every slot.
    private func readMegaSnapshot() async throws -> Snapshot {
        let frame = try await request(Command.workState(), timeout: 6) {
            if case .workStates = $0 { true } else { false }
        }
        guard case .workStates(let statuses) = frame else { throw ChargerError.timeout }

        try? await Task.sleep(for: .milliseconds(100))
        var snapshot = Snapshot(statuses: statuses)
        if let input = try? await readInput() {
            snapshot.inputMillivolts = input.millivolts
            snapshot.inputMilliamps = input.milliamps
        }
        return snapshot
    }

    /// A4/C4: WorkState + Electric per channel. WorkState carries the stored settings; Electric
    /// carries the live output voltage and charge current.
    private func readChannelSnapshot() async throws -> Snapshot {
        var statuses = (0..<kind.channelCount).map { SlotStatus(slot: $0) }
        var configs: [Int: SlotConfig] = [:]
        var input: (Int, Int)?
        var answered = 0

        for channel in 0..<kind.channelCount {
            let slot = kind.slot(forChannel: channel)
            // A channel that doesn't answer (e.g. the unused bay layout) just stays empty.
            guard let reply = try? await request(Command.workState(channel: channel), timeout: 3, match: {
                if case .channelWorkState(let ws) = $0 { ws.channel == channel } else { false }
            }), case .channelWorkState(let ws) = reply else { continue }
            answered += 1
            try? await Task.sleep(for: .milliseconds(100))

            var outputMV = 0, chargeMA = 0
            if let reply = try? await request(Command.electric(channel: channel), timeout: 3, match: {
                if case .channelElectric(let c, _, _, _, _) = $0 { c == channel } else { false }
            }), case .channelElectric(_, let inMV, let inMA, let outMV, let chMA) = reply {
                outputMV = outMV
                chargeMA = chMA
                if input == nil { input = (inMV, inMA) }
            }
            try? await Task.sleep(for: .milliseconds(100))

            statuses[slot] = ws.status(slot: slot, voltageMV: outputMV, currentMA: chargeMA)
            configs[slot] = ws.config
        }
        if answered == 0 { throw ChargerError.timeout }
        return Snapshot(statuses: statuses, configs: configs, inputMillivolts: input?.0, inputMilliamps: input?.1)
    }

    func readInput() async throws -> (millivolts: Int, milliamps: Int) {
        let frame = try await request(Command.electric(), timeout: 4) {
            if case .electric = $0 { true } else { false }
        }
        guard case .electric(let mV, let mA) = frame else { throw ChargerError.timeout }
        return (mV, mA)
    }

    /// The charger's stored settings by display slot. `slots` limits an A4/C4 read to those slots
    /// (each costs a request); the A8 returns all eight in one reply.
    func readSlotConfigs(slots: [Int]? = nil) async throws -> [Int: SlotConfig] {
        if kind.usesMegaPacket {
            let frame = try await request(Command.taskRequest, timeout: 5) {
                if case .slotConfigs = $0 { true } else { false }
            }
            guard case .slotConfigs(let configs) = frame else { throw ChargerError.timeout }
            return Dictionary(uniqueKeysWithValues: configs.enumerated().map { ($0.offset, $0.element) })
        }
        var result: [Int: SlotConfig] = [:]
        for slot in slots ?? Array(0..<kind.channelCount) {
            let channel = kind.channel(forSlot: slot)
            let reply = try await request(Command.workState(channel: channel), timeout: 3) {
                if case .channelWorkState(let ws) = $0 { ws.channel == channel } else { false }
            }
            if case .channelWorkState(let ws) = reply { result[slot] = ws.config }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return result
    }

    // MARK: Writes

    /// Writes one slot's settings. Throws `.rejected` if the charger answers with an error;
    /// returns `.unacknowledged` if it simply doesn't answer (callers verify by reading back).
    func writeSlot(_ slot: Int, config: SlotConfig) async throws -> WriteOutcome {
        let channel = kind.channel(forSlot: slot)
        let command = Command.workTask(channel: channel, config: config)
        do {
            let reply = try await request(command, timeout: 2.5) {
                if case .workTaskAck(let c, _) = $0 { c == channel } else { false }
            }
            if case .workTaskAck(_, let ok) = reply, !ok { throw ChargerError.rejected(slot: slot) }
            return .acknowledged
        } catch ChargerError.timeout {
            return .unacknowledged
        }
    }

    // MARK: Plumbing

    private func request(_ command: Data, timeout: Double, match: @escaping (Frame) -> Bool) async throws -> Frame {
        try await lock.withLock {
            try await frames.wait(timeout: timeout, match: match) { [self] in
                onTraffic?("→", "AF01", command)
                try await transport.write(command, to: .data)
            }
        }
    }

    private func writeSetup(_ data: Data) async throws {
        onTraffic?("→", "AF02", data)
        try await transport.write(data, to: .setup)
    }

    private func receive(_ data: Data) {
        onTraffic?("←", "AF01", data)
        for chunk in assembler.push(data) {
            if let frame = FrameParser.parse(chunk, kind: kind) { frames.deliver(frame) }
        }
    }

    private func receiveSetup(_ data: Data) {
        onTraffic?("←", "AF02", data)
        if FrameParser.parseBindResult(data) == 1 { onBindWaiting?() }
        setupMessages.deliver(data)
    }
}
