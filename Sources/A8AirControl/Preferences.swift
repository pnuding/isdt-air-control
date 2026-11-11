import Foundation
import ISDTCore

/// UserDefaults keys. Preferences are read from UserDefaults at the moment they matter (and
/// bound with @AppStorage in the settings UI), so changing one takes effect immediately without
/// a model mirroring it.
enum Pref {
    static let notifyOnDone = "notifyOnDone"
    static let notifyOnError = "notifyOnError"
    static let notificationSound = "notificationSound"
    static let pollInterval = "pollInterval"
    static let trafficLogging = "trafficLogging"
    static let bindUUID = "bindUUID"
    /// JSON list of the chargers this Mac knows: [{id, kind}].
    static let chargers = "chargers"
    // Pre-multi-charger single-device keys, migrated once.
    static let legacyDeviceID = "deviceID"
    static let legacyDeviceName = "deviceName"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyOnDone: true,
            notifyOnError: true,
            notificationSound: true,
            pollInterval: 3.0,
            trafficLogging: false,
        ])
    }

    /// One random UUID per install, shared by all chargers, so each recognises this Mac without re-pairing.
    static func clientUUID() -> Data {
        let defaults = UserDefaults.standard
        if let hex = defaults.string(forKey: bindUUID), hex.count == 32 {
            let bytes = stride(from: 0, to: 32, by: 2).compactMap { i -> UInt8? in
                let start = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
            }
            if bytes.count == 16 { return Data(bytes) }
        }
        let uuid = UUID()
        let data = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        defaults.set(data.map { String(format: "%02x", $0) }.joined(), forKey: bindUUID)
        return data
    }
}

/// A charger remembered across launches.
struct SavedCharger: Codable, Equatable {
    var id: UUID
    var kind: ChargerKind
}

/// Outcome of the most recent settings write to one slot.
enum ApplyResult: Equatable {
    case pending
    /// Read back from the charger and matches what was sent.
    case verified
    /// The charger stored something different (it clamped or ignored a value).
    case adjusted(SlotConfig)
    /// Sent, but the charger neither acknowledged nor could be read back.
    case unconfirmed
    case failed(String)
}
