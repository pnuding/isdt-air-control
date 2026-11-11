import Foundation

/// Constants that describe the ISDT A8 Air and its BLE service.
public enum ISDT {
    public static let serviceUUID = "0000AF00-0000-1000-8000-00805F9B34FB"
    /// Polling and control (read/write commands, responses arrive as notifications).
    public static let dataCharacteristicUUID = "0000AF01-0000-1000-8000-00805F9B34FB"
    /// Connection setup: bind handshake and hardware info.
    public static let setupCharacteristicUUID = "0000AF02-0000-1000-8000-00805F9B34FB"

    /// Bluetooth company ID ISDT advertises its manufacturer data under.
    public static let manufacturerID: UInt16 = 0xABBA

    public static let slotCount = 8
    /// Per-slot charge current limits of the A8 Air (mA).
    public static let currentRange = 100...1000
    public static let currentStep = 50
}

// MARK: - Battery chemistry

/// Battery chemistries the A8 Air can be told to charge. Raw values are the
/// wire values used by `WorkTasksReq` / `A8TaskResp`.
public enum BatteryType: UInt8, CaseIterable, Identifiable, Sendable {
    case liHV = 0
    case liIon = 1
    case liFe = 2
    case niZn = 3
    case niMHCd = 4
    case liIon15V = 5
    case auto = 6

    public var id: UInt8 { rawValue }

    public var displayName: String {
        switch self {
        case .liHV: "LiHV"
        case .liIon: "Li-ion"
        case .liFe: "LiFePO4"
        case .niZn: "NiZn"
        case .niMHCd: "NiMH / NiCd"
        case .liIon15V: "Li-ion 1.5 V"
        case .auto: String(localized: "Auto")
        }
    }

    /// Compact label for tight spaces (slot columns).
    public var shortName: String {
        switch self {
        case .liHV: "LiHV"
        case .liIon: "Li-ion"
        case .liFe: "LiFe"
        case .niZn: "NiZn"
        case .niMHCd: "NiMH"
        case .liIon15V: "Li 1.5V"
        case .auto: String(localized: "Auto")
        }
    }

    public var detail: String {
        switch self {
        case .liHV: String(localized: "High-voltage lithium, 4.35 V")
        case .liIon: String(localized: "Standard lithium-ion, 4.20 V")
        case .liFe: String(localized: "Lithium iron phosphate, 3.65 V")
        case .niZn: String(localized: "Nickel-zinc, 1.9 V")
        case .niMHCd: String(localized: "Nickel metal hydride / cadmium")
        case .liIon15V: String(localized: "Regulated 1.5 V lithium cells")
        case .auto: String(localized: "Charger detects the chemistry")
        }
    }

    public var limits: BatteryLimits {
        switch self {
        case .liHV:
            BatteryLimits(capacity: 2000...7000, cutoff: 4250...4450, cutoffDefault: 4350, cutoffIsDelta: false)
        case .liIon:
            BatteryLimits(capacity: 2000...7000, cutoff: 4100...4300, cutoffDefault: 4200, cutoffIsDelta: false)
        case .liFe:
            BatteryLimits(capacity: 2000...7000, cutoff: 3550...3750, cutoffDefault: 3650, cutoffIsDelta: false)
        case .niZn:
            BatteryLimits(capacity: 2000...7000, cutoff: 1800...2000, cutoffDefault: 1900, cutoffIsDelta: false)
        case .niMHCd:
            // Cut-off is a delta-peak (−ΔV) in mV, not an absolute voltage.
            BatteryLimits(capacity: 1000...4000, cutoff: 3...12, cutoffDefault: 4, cutoffIsDelta: true)
        case .liIon15V:
            BatteryLimits(capacity: 1000...4000, cutoff: nil, cutoffDefault: 0, cutoffIsDelta: false)
        case .auto:
            BatteryLimits(capacity: nil, cutoff: nil, cutoffDefault: 0, cutoffIsDelta: false)
        }
    }
}

/// Settable ranges per chemistry, taken from the ISD Link app as documented
/// by the ISDT Charge Utility project.
public struct BatteryLimits: Equatable, Sendable {
    /// Allowed capacity-limit range in mAh (0 = unlimited is always allowed). `nil` = not configurable.
    public let capacity: ClosedRange<Int>?
    /// Allowed cut-off range in mV. `nil` = not configurable.
    public let cutoff: ClosedRange<Int>?
    public let cutoffDefault: Int
    /// True when the cut-off is a delta-peak (ΔmV) instead of an absolute voltage.
    public let cutoffIsDelta: Bool

    public var usesCurrent: Bool { capacity != nil || cutoff != nil }
}

// MARK: - Per-slot settings

/// The settings of one slot as the charger stores them (`A8TaskResp`) and as
/// they are written back (`WorkTasksReq`).
public struct SlotConfig: Equatable, Sendable {
    public var batteryType: BatteryType
    /// Charge current in mA. 0 = the charger's own default: a real A8 Air reports 0 for every
    /// slot while charging at about 500 mA.
    public var currentMA: Int
    /// Cut-off in mV: an absolute voltage, or a delta-peak for NiMH/NiCd. 0 = charger default.
    public var cutoffMV: Int
    /// Safety capacity limit in mAh. 0 = unlimited.
    public var capacityLimitMAh: Int

    public init(batteryType: BatteryType, currentMA: Int, cutoffMV: Int, capacityLimitMAh: Int) {
        self.batteryType = batteryType
        self.currentMA = currentMA
        self.cutoffMV = cutoffMV
        self.capacityLimitMAh = capacityLimitMAh
    }

    /// Safe starting values for a chemistry (300 mA, chemistry default cut-off, no capacity limit).
    public static func defaults(for type: BatteryType) -> SlotConfig {
        if type == .auto {
            return SlotConfig(batteryType: .auto, currentMA: 0, cutoffMV: 0, capacityLimitMAh: 0)
        }
        return SlotConfig(batteryType: type, currentMA: 300, cutoffMV: type.limits.cutoffDefault, capacityLimitMAh: 0)
    }

    /// Switching chemistry: keep the user's current, reset the chemistry-specific fields.
    public func switching(to type: BatteryType, currentRange: ClosedRange<Int> = ISDT.currentRange) -> SlotConfig {
        var next = SlotConfig.defaults(for: type)
        if type != .auto, batteryType != .auto {
            next.currentMA = currentMA == 0 ? 0 : min(max(currentMA, currentRange.lowerBound), currentRange.upperBound)
        }
        return next
    }

    /// Human-readable reasons this config must not be sent. Empty = valid.
    public var validationIssues: [String] { issues(currentRange: ISDT.currentRange) }

    public func isValid(currentRange: ClosedRange<Int>) -> Bool { issues(currentRange: currentRange).isEmpty }

    public func issues(currentRange: ClosedRange<Int>) -> [String] {
        if batteryType == .auto { return [] }
        let limits = batteryType.limits
        var issues: [String] = []
        if currentMA != 0, !currentRange.contains(currentMA) {
            issues.append(String(localized: "Current must be the charger default or \(String(currentRange.lowerBound))–\(String(currentRange.upperBound)) mA."))
        }
        if let range = limits.cutoff, !range.contains(cutoffMV) {
            let unit = limits.cutoffIsDelta ? "ΔmV" : "mV"
            issues.append(String(localized: "Cut-off must be \(String(range.lowerBound))–\(String(range.upperBound)) \(unit)."))
        }
        if let range = limits.capacity, capacityLimitMAh != 0, !range.contains(capacityLimitMAh) {
            issues.append(String(localized: "Capacity limit must be off or \(String(range.lowerBound))–\(String(range.upperBound)) mAh."))
        }
        return issues
    }

    public var isValid: Bool { validationIssues.isEmpty }

    public var usesDefaultCurrent: Bool { currentMA == 0 }

    /// Equality that ignores fields the chemistry doesn't use (e.g. everything but the type for Auto).
    public func matches(_ other: SlotConfig) -> Bool {
        guard batteryType == other.batteryType else { return false }
        if batteryType == .auto { return true }
        let limits = batteryType.limits
        if currentMA != other.currentMA { return false }
        if limits.cutoff != nil, cutoffMV != other.cutoffMV { return false }
        if limits.capacity != nil, capacityLimitMAh != other.capacityLimitMAh { return false }
        return true
    }
}

// MARK: - Live status

public enum ChargePhase: Equatable, Sendable {
    /// No battery detected in the slot.
    case empty
    case idle
    case preCharge
    case constantCurrent
    case charging
    case constantVoltage
    case error
    case done
    case unknown(UInt8)

    /// True while current is being pushed into a battery.
    public var isCharging: Bool {
        switch self {
        case .preCharge, .constantCurrent, .charging, .constantVoltage: true
        default: false
        }
    }
}

public struct SlotStatus: Equatable, Identifiable, Sendable {
    /// 0-based slot index (slot 1 on the device = 0).
    public var slot: Int
    public var phase: ChargePhase
    public var rawState: UInt8
    public var capacityPercent: Int
    public var chargedMAh: Int
    public var energyMWh: Int
    /// Time the current charge session has been running.
    public var elapsed: TimeInterval
    public var rawBatteryType: UInt8
    public var currentMA: Int
    public var voltageMV: Int
    /// Internal resistance in mΩ. 0 when the charger has no reading.
    public var internalResistanceMilliohm: Double
    public var errorCode: Int

    public var id: Int { slot }
    public var batteryType: BatteryType? { BatteryType(rawValue: rawBatteryType) }
    public var voltage: Double { Double(voltageMV) / 1000 }
    public var hasBattery: Bool { phase != .empty }

    public init(slot: Int, phase: ChargePhase = .empty, rawState: UInt8 = 0, capacityPercent: Int = 0,
                chargedMAh: Int = 0, energyMWh: Int = 0, elapsed: TimeInterval = 0, rawBatteryType: UInt8 = 6,
                currentMA: Int = 0, voltageMV: Int = 0, internalResistanceMilliohm: Double = 0, errorCode: Int = 0) {
        self.slot = slot
        self.phase = phase
        self.rawState = rawState
        self.capacityPercent = capacityPercent
        self.chargedMAh = chargedMAh
        self.energyMWh = energyMWh
        self.elapsed = elapsed
        self.rawBatteryType = rawBatteryType
        self.currentMA = currentMA
        self.voltageMV = voltageMV
        self.internalResistanceMilliohm = internalResistanceMilliohm
        self.errorCode = errorCode
    }

    /// An idle slot reading below this voltage is treated as having no battery in it.
    public static let emptyVoltageThresholdMV = 500

    public static func phase(forRawState raw: UInt8, voltageMV: Int) -> ChargePhase {
        switch raw {
        case 0: voltageMV < emptyVoltageThresholdMV ? .empty : .idle
        case 1: .preCharge
        case 2: .constantCurrent
        case 3: .charging
        case 4: .constantVoltage
        case 5: .error
        case 6: .done
        default: .unknown(raw)
        }
    }
}

/// Firmware / hardware info from `HardwareInfoResp`.
public struct HardwareInfo: Equatable, Sendable {
    public var hardwareVersion: String
    public var firmwareVersion: String
    /// Not every firmware fills this; nil when it's text or all 0x00 / 0xFF.
    public var serialNumber: String?

    public init(hardwareVersion: String, firmwareVersion: String, serialNumber: String?) {
        self.hardwareVersion = hardwareVersion
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
    }
}

/// What an ISDT device advertises.
public struct Advertisement: Equatable, Sendable {
    /// Hex of the 4-byte model ID, e.g. "010f00a8".
    public var modelID: String
    public var modelName: String?

    public var isA8Air: Bool { modelName == "A8 Air" }
    /// The charger family this app can drive, if it's one of them.
    public var chargerKind: ChargerKind? { ChargerKind(modelName: modelName) }

    public init(modelID: String, modelName: String?) {
        self.modelID = modelID
        self.modelName = modelName
    }

    private static let models: [String: String] = [
        "01010000": "K4", "81010000": "K4", "01020000": "X16", "01030000": "Air 8",
        "01040000": "K2 Air", "01050000": "NP2 Air", "81050000": "NP2 Air",
        "01060000": "LP2 Air", "81060000": "LP2 Air", "01070000": "C4 Air",
        "01080000": "Power 200", "010b0000": "PB10DW", "010b0001": "PB10DW",
        "010c0000": "PB50DW", "010d0000": "Power 200H", "010e0000": "Power 200X",
        "010f0000": "A4 Air", "810f0000": "A4 Air", "010f00a8": "A8 Air", "810f00a8": "A8 Air",
        "01100000": "PB70W", "01100001": "PB70W", "01110000": "EDGE",
        "01120000": "PB25DW", "01120001": "PB25DW", "01c00000": "608PD", "81c00000": "608PD",
        "81c00100": "PB25DW", "81c00200": "PB50DW", "01350000": "MASS2",
    ]

    /// Parses CoreBluetooth manufacturer data (company ID first, little-endian).
    /// Returns nil for anything that isn't an ISDT advertisement.
    public static func parse(manufacturerData data: Data?) -> Advertisement? {
        guard let data else { return nil }
        let b = [UInt8](data)
        // 2 bytes company ID (BA AB), 2 bytes magic (AF FA), 4 bytes model ID.
        guard b.count >= 8,
              UInt16(b[0]) | UInt16(b[1]) << 8 == ISDT.manufacturerID,
              b[2] == 0xAF, b[3] == 0xFA else { return nil }
        let modelID = b[4..<8].map { String(format: "%02x", $0) }.joined()
        var name = models[modelID]
        if name == nil, b.count > 8 {
            // Newer models embed their name as NUL-terminated ASCII at payload offset 6.
            let tail = b[8...].prefix { $0 != 0 }
            if let text = String(bytes: tail, encoding: .ascii)?.trimmingCharacters(in: .whitespaces),
               !text.isEmpty, text.allSatisfy({ $0.isASCII && !$0.isWhitespace || $0 == " " }) {
                name = switch text { case "A8Air": "A8 Air"; case "A4Air": "A4 Air"; case "C4Air": "C4 Air"; default: text }
            }
        }
        return Advertisement(modelID: modelID, modelName: name)
    }
}
