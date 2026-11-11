import ISDTCore
import SwiftUI

extension ChargePhase {
    var label: String {
        switch self {
        case .empty: String(localized: "Empty")
        case .idle: String(localized: "Idle")
        case .preCharge: String(localized: "Pre-charge")
        case .constantCurrent: String(localized: "Charging")
        case .charging: String(localized: "Charging")
        case .constantVoltage: String(localized: "Topping off")
        case .error: String(localized: "Error")
        case .done: String(localized: "Done")
        case .unknown(let raw): String(localized: "State \(Int(raw))")
        }
    }

    var symbol: String {
        switch self {
        case .empty: "circle.dashed"
        case .idle: "pause.circle"
        case .preCharge, .constantCurrent, .charging, .constantVoltage: "bolt.fill"
        case .error: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .empty, .idle, .unknown: .secondary
        case .preCharge, .constantCurrent, .charging, .constantVoltage: .blue
        case .error: .red
        case .done: .green
        }
    }
}

enum Format {
    static func voltage(_ millivolts: Int) -> String {
        String(format: "%.2f V", Double(millivolts) / 1000)
    }

    static func milliamps(_ value: Int) -> String { "\(value) mA" }

    static func milliampHours(_ value: Int) -> String {
        value.formatted(.number.grouping(.never)) + " mAh"
    }

    /// 2:41:07 for an hour or more, 41:07 below that.
    static func elapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "Li-ion · 500 mA · 4.20 V" — a compact description of stored slot settings.
    static func summary(_ config: SlotConfig) -> String {
        guard config.batteryType != .auto else { return String(localized: "Auto") }
        var parts = [config.batteryType.displayName, config.usesDefaultCurrent ? String(localized: "default current") : milliamps(config.currentMA)]
        let limits = config.batteryType.limits
        if limits.cutoff != nil {
            parts.append(limits.cutoffIsDelta ? String(localized: "−Δ\(String(config.cutoffMV)) mV") : voltage(config.cutoffMV))
        }
        if limits.capacity != nil, config.capacityLimitMAh > 0 {
            parts.append(String(localized: "≤ \(String(config.capacityLimitMAh)) mAh"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Glass

private struct GlassEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False only for the dev-only off-screen preview, where `.glassEffect` draws nothing at all.
    var glassEnabled: Bool {
        get { self[GlassEnabledKey.self] }
        set { self[GlassEnabledKey.self] = newValue }
    }
}

private struct GlassCardModifier<S: Shape>: ViewModifier {
    @Environment(\.glassEnabled) private var enabled
    let glass: Glass
    let shape: S

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(glass, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// Liquid Glass surface (the same as `glassEffect`, but previewable off-screen).
    func glassCard<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(GlassCardModifier(glass: glass, shape: shape))
    }
}
