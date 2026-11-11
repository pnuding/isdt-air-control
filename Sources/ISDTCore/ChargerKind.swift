import Foundation

/// The ISDT chargers this app speaks to. They share the BLE service and bind handshake but
/// differ in how status is reported and in how many slots they have.
public enum ChargerKind: String, Codable, CaseIterable, Sendable {
    case a8Air
    case a4Air
    case c4Air

    public init?(modelName: String?) {
        switch modelName {
        case "A8 Air": self = .a8Air
        case "A4 Air": self = .a4Air
        case "C4 Air": self = .c4Air
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .a8Air: "A8 Air"
        case .a4Air: "A4 Air"
        case .c4Air: "C4 Air"
        }
    }

    /// Protocol channels the charger reports.
    public var channelCount: Int {
        switch self {
        case .a8Air: 8
        case .a4Air: 4
        case .c4Air: 6
        }
    }

    /// A8: all slots in one 203-byte packet. A4/C4: one WorkState + Electric request per channel.
    public var usesMegaPacket: Bool { self == .a8Air }

    /// The A4 numbers its channels in the opposite direction to its physical slots.
    public var slotsReversed: Bool { self == .a4Air }

    /// Per-slot charge current limits (mA).
    public var currentRange: ClosedRange<Int> {
        switch self {
        case .a8Air, .a4Air: 100...1000
        case .c4Air: 100...2000
        }
    }

    /// Protocol channel behind display slot `slot` (0-based, in physical order).
    public func channel(forSlot slot: Int) -> Int {
        slotsReversed ? channelCount - 1 - slot : slot
    }

    public func slot(forChannel channel: Int) -> Int {
        slotsReversed ? channelCount - 1 - channel : channel
    }

    /// The C4 Air's six channels are two alternative bay layouts: 1–4 or 5–6 (the larger cells).
    public static let c4LargeBays = [4, 5]
    public static let c4SmallBays = [0, 1, 2, 3]

    /// Which slots to show. For the C4 this follows whichever bay layout holds batteries; with
    /// neither populated it keeps `previouslyLarge`.
    public func visibleSlots(in slots: [SlotStatus], c4UsesLargeBays: inout Bool) -> [Int] {
        switch self {
        case .a8Air, .a4Air:
            return Array(0..<channelCount)
        case .c4Air:
            let small = Self.c4SmallBays.contains { $0 < slots.count && slots[$0].hasBattery }
            let large = Self.c4LargeBays.contains { $0 < slots.count && slots[$0].hasBattery }
            if small { c4UsesLargeBays = false } else if large { c4UsesLargeBays = true }
            return c4UsesLargeBays ? Self.c4LargeBays : Self.c4SmallBays
        }
    }
}
