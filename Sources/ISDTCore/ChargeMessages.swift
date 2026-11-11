import Foundation

/// Wording for charge notifications. Every string is localized through `String(localized:)`,
/// which looks in the app bundle's Localizable.strings (the English text is the fallback).
public enum ChargeMessages {
    /// "Slot 3 is fully charged" / "Slots 1, 3 and 4 are fully charged", with a body describing each.
    public static func completion(finished: [Int], slots: [SlotStatus]) -> (title: String, body: String) {
        let finished = finished.sorted()
        guard let first = finished.first else { return ("", "") }

        let title = finished.count == 1
            ? String(localized: "Slot \(first + 1) is fully charged")
            : String(localized: "\(slotList(finished)) are fully charged")

        var body: String
        if finished.count == 1 {
            let s = slots[first]
            var parts: [String] = []
            if let type = s.batteryType, type != .auto { parts.append(type.displayName) }
            parts.append(String(localized: "\(String(s.chargedMAh)) mAh in \(duration(s.elapsed))"))
            if s.voltageMV > 0 { parts.append(String(format: "%.2f V", s.voltage)) }
            body = parts.joined(separator: " · ")
        } else {
            body = finished.map { String(localized: "Slot \($0 + 1): \(String(slots[$0].chargedMAh)) mAh") }.joined(separator: ", ")
        }

        if !slots.contains(where: { $0.phase.isCharging }) {
            body = String(localized: "\(body). All slots are finished.")
        }
        return (title, body)
    }

    public static func error(failed: [Int], slots: [SlotStatus]) -> (title: String, body: String) {
        let failed = failed.sorted()
        let names = slotList(failed)
        let codes = failed.compactMap { slots[$0].errorCode != 0 ? String(localized: "Slot \($0 + 1): code \(String(slots[$0].errorCode))") : nil }
        return (
            failed.count == 1 ? String(localized: "\(names) reported an error") : String(localized: "\(names) reported errors"),
            codes.isEmpty ? String(localized: "Check the battery and the contacts.") : codes.joined(separator: ", ")
        )
    }

    /// 0-based slot indices → "Slot 3" / "Slots 1, 3 and 4".
    public static func slotList(_ slots: [Int]) -> String {
        let numbers = slots.sorted().map { String($0 + 1) }
        switch numbers.count {
        case 0: return ""
        case 1: return String(localized: "Slot \(numbers[0])")
        default: return String(localized: "Slots \(numbers.dropLast().joined(separator: ", ")) and \(numbers.last!)")
        }
    }

    /// "2h 41m" / "41m".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let (h, m) = (minutes / 60, minutes % 60)
        return h > 0 ? String(localized: "\(h)h \(m)m") : String(localized: "\(m)m")
    }
}
