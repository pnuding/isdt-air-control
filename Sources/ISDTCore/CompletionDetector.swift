import Foundation

public enum ChargeEvent: Equatable, Sendable {
    /// The slot went from actively charging to done.
    case finished(slot: Int)
    /// The slot newly entered the error state.
    case failed(slot: Int)
}

/// Turns a stream of status snapshots into one-shot events.
///
/// It remembers the last phase of every slot, including across BLE
/// reconnects, so a charge that finishes while the link is briefly down is
/// still reported on the first snapshot after reconnecting. The very first
/// snapshot never produces events (a slot that is already done when the app
/// starts has not "just finished").
public struct CompletionDetector: Sendable {
    private var lastPhase: [Int: ChargePhase] = [:]

    public init() {}

    public mutating func ingest(_ slots: [SlotStatus]) -> [ChargeEvent] {
        var events: [ChargeEvent] = []
        for status in slots {
            defer { lastPhase[status.slot] = status.phase }
            guard let previous = lastPhase[status.slot] else { continue }
            if previous.isCharging, status.phase == .done {
                events.append(.finished(slot: status.slot))
            } else if previous != .error, status.phase == .error {
                events.append(.failed(slot: status.slot))
            }
        }
        return events
    }

    public mutating func reset() { lastPhase.removeAll() }
}
