import Foundation

/// Byte-level commands for the A8 Air. Sources: the mtheli/isdt_air_ble
/// protocol notes (reading) and DittelHome/ISDT-Charge-Utility (writing).
public enum Command {
    /// Slot status. The A8 answers channel 0 with a "mega-packet" covering all 8 slots; the A4/C4
    /// answer per channel.
    public static func workState(channel: Int = 0) -> Data { Data([0x13, 0xE6, UInt8(channel)]) }
    /// Input voltage / current (A8: device-level, channel 0), plus output voltage/current per channel on the A4/C4.
    public static func electric(channel: Int = 0) -> Data { Data([0x12, 0xE4, UInt8(channel)]) }
    /// Stored per-slot settings (battery type, current, cut-off, capacity limit).
    public static let taskRequest = Data([0x12, 0xEC, 0x00])
    /// AF02: ask for HW/FW version and serial.
    public static let hardwareInfo = Data([0xE0])

    /// AF02: register this client with the charger. The UUID must stay stable
    /// across launches so the charger doesn't ask for re-pairing.
    public static func bind(clientUUID: Data) -> Data {
        precondition(clientUUID.count == 16)
        return Data([0x18]) + clientUUID + Data([0x00, 0x01])
    }

    /// `WorkTasksReq`: write a slot's settings. This is what the ISD Link app
    /// sends to start a charge, so it (re)starts charging on a populated slot.
    public static func workTask(channel: Int, config: SlotConfig) -> Data {
        // "Auto" sends zeros for everything except the battery type.
        let isAuto = config.batteryType == .auto
        let current = isAuto ? 0 : config.currentMA
        let cutoff = isAuto ? 0 : config.cutoffMV
        let capacity = isAuto ? 0 : config.capacityLimitMAh

        var out = Data([0x13, 0xEA, UInt8(channel), 0x00 /* task: charge */, config.batteryType.rawValue, 0x00 /* link */])
        out.append(le32(current))
        out.append(0x00) // cell count: 0 = auto
        out.append(le16(cutoff))
        out.append(le32(capacity))
        return out
    }

    private static func le16(_ v: Int) -> Data {
        let x = UInt16(clamping: v)
        return Data([UInt8(x & 0xFF), UInt8(x >> 8)])
    }

    private static func le32(_ v: Int) -> Data {
        let x = UInt32(clamping: v)
        return Data([UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF), UInt8((x >> 16) & 0xFF), UInt8(x >> 24)])
    }
}

/// A decoded AF01 notification.
public enum Frame: Equatable, Sendable {
    /// A8: all slots at once.
    case workStates([SlotStatus])
    /// A4/C4: one channel.
    case channelWorkState(ChannelWorkState)
    /// A8: 9-byte input-only reply.
    case electric(inputMV: Int, inputMA: Int)
    /// A4/C4: input plus this channel's output voltage and charge current.
    case channelElectric(channel: Int, inputMV: Int, inputMA: Int, outputMV: Int, chargeMA: Int)
    case slotConfigs([SlotConfig])
    /// Reply to `WorkTasksReq`. `ok` is false when the charger reported an error.
    case workTaskAck(channel: Int, ok: Bool)
    case unknown(opcode: UInt8)
}

public enum FrameParser {
    static let header: UInt8 = 0x31
    static let workStateOpcode: UInt8 = 0xE7
    static let electricOpcode: UInt8 = 0xE5
    static let taskOpcode: UInt8 = 0xED
    static let workTaskAckOpcode: UInt8 = 0xEB

    static let workStateBlock = 25
    static let taskBlock = 12

    /// Internal resistance unit of the A8 mega-packet. mtheli/isdt_air_ble documents
    /// 0.1 mΩ; DittelHome/ISDT-Charge-Utility found 0.01 mΩ on real A8 hardware.
    /// Treated as 0.01 mΩ here; unverified, so IR is shown only as a secondary detail.
    static let internalResistanceUnitMilliohm = 0.01

    public static func parse(_ data: Data, kind: ChargerKind = .a8Air) -> Frame? {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == header else { return nil }
        switch b[1] {
        case workStateOpcode: return kind.usesMegaPacket ? parseWorkStates(b) : parseChannelWorkState(b)
        case electricOpcode: return parseElectric(b)
        case taskOpcode: return parseSlotConfigs(b)
        case workTaskAckOpcode:
            return .workTaskAck(channel: Int(b[2]), ok: b.count < 4 || b[3] == 0)
        default: return .unknown(opcode: b[1])
        }
    }

    static func parseWorkStates(_ b: [UInt8]) -> Frame? {
        let n = Int(b[2])
        guard (1...ISDT.slotCount).contains(n), b.count >= 3 + n * workStateBlock else { return nil }
        var slots: [SlotStatus] = []
        for i in 0..<n {
            let o = 3 + i * workStateBlock
            let raw = b[o]
            let voltage = le16(b, o + 19)
            slots.append(SlotStatus(
                slot: i,
                phase: SlotStatus.phase(forRawState: raw, voltageMV: voltage),
                rawState: raw,
                capacityPercent: min(Int(b[o + 1]), 100),
                chargedMAh: le32(b, o + 2),
                energyMWh: le32(b, o + 6),
                elapsed: TimeInterval(le32(b, o + 10)) / 1000,
                rawBatteryType: b[o + 14],
                currentMA: le32(b, o + 15),
                voltageMV: voltage,
                internalResistanceMilliohm: Double(le16(b, o + 21)) * internalResistanceUnitMilliohm,
                errorCode: le16(b, o + 23)
            ))
        }
        return .workStates(slots)
    }

    static func parseElectric(_ b: [UInt8]) -> Frame? {
        // A8: 9 bytes = header, opcode, channel, input mV (2), input mA (4).
        guard b.count >= 9 else { return nil }
        guard b.count >= 15 else { return .electric(inputMV: le16(b, 3), inputMA: le32(b, 5)) }
        // A4/C4: short form (≤ 35 bytes) has 2-byte voltages, long form 4-byte ones.
        if b.count > 35 {
            return .channelElectric(channel: Int(b[2]), inputMV: le32(b, 3), inputMA: le32(b, 7),
                                    outputMV: le32(b, 11), chargeMA: le32(b, 15))
        }
        return .channelElectric(channel: Int(b[2]), inputMV: le16(b, 3), inputMA: le32(b, 5),
                                outputMV: le16(b, 9), chargeMA: le32(b, 11))
    }

    /// A4/C4 per-channel WorkState (36+ bytes). It carries the slot's settings as well as its status.
    static func parseChannelWorkState(_ b: [UInt8]) -> Frame? {
        guard b.count >= 36 else { return nil }
        return .channelWorkState(ChannelWorkState(
            channel: Int(b[2]),
            rawState: b[3],
            capacityPercent: min(Int(b[4]), 100),
            chargedMAh: le32(b, 5),
            energyMWh: le32(b, 9),
            elapsed: TimeInterval(le32(b, 13)) / 1000,
            rawBatteryType: b[17],
            fullChargedMV: le16(b, 20),
            workCurrentMA: le32(b, 22),
            capacityLimitMAh: le32(b, 32),
            errorCode: b.count >= 38 ? le16(b, 36) : 0
        ))
    }

    static func parseSlotConfigs(_ b: [UInt8]) -> Frame? {
        let n = Int(b[2])
        guard (1...ISDT.slotCount).contains(n), b.count >= 3 + n * taskBlock else { return nil }
        var configs: [SlotConfig] = []
        for i in 0..<n {
            let o = 3 + i * taskBlock
            // o+0 is the task type (charge/discharge/...), not needed here.
            configs.append(SlotConfig(
                batteryType: BatteryType(rawValue: b[o + 1]) ?? .auto,
                currentMA: le32(b, o + 2),
                cutoffMV: le16(b, o + 6),
                capacityLimitMAh: le32(b, o + 8)
            ))
        }
        return .slotConfigs(configs)
    }

    /// `HardwareInfoResp` on AF02. Some firmwares prefix the 0x31 header, others don't.
    public static func parseHardwareInfo(_ data: Data) -> HardwareInfo? {
        var b = [UInt8](data)
        if b.count >= 14, b[0] == header, b[1] == 0xE1 { b.removeFirst() }
        guard b.count >= 13, b[0] == 0xE1 else { return nil }
        let idBytes = Array(b[5..<13])
        let isPlaceholder = idBytes.allSatisfy { $0 == 0x00 } || idBytes.allSatisfy { $0 == 0xFF }
        let looksLikeText = idBytes.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) }
        var serial: String?
        if !isPlaceholder, !looksLikeText {
            let value = idBytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            serial = String(value)
        }
        return HardwareInfo(
            hardwareVersion: "\(b[1]).\(b[2])",
            firmwareVersion: "\(b[3]).\(b[4])",
            serialNumber: serial
        )
    }

    /// `BindResp` on AF02: nil if not a bind response, else the result (0 = bound, 1 = waiting for a button press).
    public static func parseBindResult(_ data: Data) -> UInt8? {
        let b = [UInt8](data)
        guard b.count >= 2, b[0] == 0x19 else { return nil }
        return b[1]
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }
}

/// Re-joins frames the charger's BLE stack split across several notifications.
///
/// The mega-packet is 203 bytes; if the negotiated ATT MTU is smaller it
/// arrives in pieces. Only frames with a known fixed length are reassembled;
/// everything else passes straight through.
public struct FrameAssembler: Sendable {
    private var pending: (data: Data, expected: Int, since: Date)?
    private let kind: ChargerKind
    /// Give up on an incomplete frame after this long.
    public var staleAfter: TimeInterval = 1.0

    public init(kind: ChargerKind = .a8Air) { self.kind = kind }

    public mutating func push(_ chunk: Data, now: Date = Date()) -> [Data] {
        if let p = pending {
            if now.timeIntervalSince(p.since) <= staleAfter {
                let joined = p.data + chunk
                if joined.count >= p.expected {
                    pending = nil
                    return [joined]
                }
                pending = (joined, p.expected, p.since)
                return []
            }
            pending = nil // stale: fall through and treat the chunk as a fresh frame
        }

        if let expected = Self.expectedLength(of: chunk, kind: kind), chunk.count < expected {
            pending = (chunk, expected, now)
            return []
        }
        return [chunk]
    }

    public mutating func reset() { pending = nil }

    static func expectedLength(of chunk: Data, kind: ChargerKind = .a8Air) -> Int? {
        let b = [UInt8](chunk.prefix(3))
        guard b.count == 3, b[0] == FrameParser.header else { return nil }
        let n = Int(b[2])
        guard (1...ISDT.slotCount).contains(n) else { return nil }
        switch b[1] {
        case FrameParser.workStateOpcode: return kind.usesMegaPacket ? 3 + n * FrameParser.workStateBlock : nil
        case FrameParser.taskOpcode: return 3 + n * FrameParser.taskBlock
        default: return nil
        }
    }
}

/// An A4/C4 per-channel WorkState reply: live status plus the channel's stored settings.
public struct ChannelWorkState: Equatable, Sendable {
    public var channel: Int
    public var rawState: UInt8
    public var capacityPercent: Int
    public var chargedMAh: Int
    public var energyMWh: Int
    public var elapsed: TimeInterval
    public var rawBatteryType: UInt8
    /// "Full charged voltage": the cut-off (an absolute mV, or a delta-peak for NiMH).
    public var fullChargedMV: Int
    /// The set charge current. 0 = charger default.
    public var workCurrentMA: Int
    /// The reply's "max output power" field, which the ISDT Charge Utility uses as the capacity limit.
    public var capacityLimitMAh: Int
    public var errorCode: Int

    public init(channel: Int, rawState: UInt8, capacityPercent: Int, chargedMAh: Int, energyMWh: Int, elapsed: TimeInterval,
                rawBatteryType: UInt8, fullChargedMV: Int, workCurrentMA: Int, capacityLimitMAh: Int, errorCode: Int) {
        self.channel = channel
        self.rawState = rawState
        self.capacityPercent = capacityPercent
        self.chargedMAh = chargedMAh
        self.energyMWh = energyMWh
        self.elapsed = elapsed
        self.rawBatteryType = rawBatteryType
        self.fullChargedMV = fullChargedMV
        self.workCurrentMA = workCurrentMA
        self.capacityLimitMAh = capacityLimitMAh
        self.errorCode = errorCode
    }

    /// Status for display slot `slot`, with the live voltage/current from the channel's Electric reply.
    public func status(slot: Int, voltageMV: Int, currentMA: Int) -> SlotStatus {
        SlotStatus(slot: slot, phase: SlotStatus.phase(forRawState: rawState, voltageMV: voltageMV), rawState: rawState,
                   capacityPercent: capacityPercent, chargedMAh: chargedMAh, energyMWh: energyMWh, elapsed: elapsed,
                   rawBatteryType: rawBatteryType, currentMA: currentMA, voltageMV: voltageMV, errorCode: errorCode)
    }

    public var config: SlotConfig {
        SlotConfig(batteryType: BatteryType(rawValue: rawBatteryType) ?? .auto, currentMA: workCurrentMA,
                   cutoffMV: fullChargedMV, capacityLimitMAh: capacityLimitMAh)
    }
}
