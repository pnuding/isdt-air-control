import ISDTCore
import SwiftUI

/// One slot drawn as a vertical battery that fills from the bottom. The eight columns sit
/// side by side in the charger's physical order, so no slot numbers are needed.
///
/// The details live inside the battery: voltage at the top, chemistry at the bottom, and
/// (while charging) a breathing bolt with the current just under it.
struct SlotColumnView: View {
    let status: SlotStatus
    let config: SlotConfig?
    let isEditing: Bool
    let hasUnappliedEdits: Bool
    /// False while disconnected: the numbers are the last known ones.
    let isLive: Bool

    private var phase: ChargePhase { status.phase }
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(spacing: 10) {
            battery
                .frame(height: 196)
            Text(headline)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(phase == .empty || phase == .idle ? Color.secondary : Color.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .glassCard(.regular.tint(tint), in: shape)
        .overlay { shape.strokeBorder(Color.accentColor, lineWidth: isEditing ? 2.5 : 0) }
        .opacity(isLive ? 1 : 0.55)
        .contentShape(shape)
        .animation(.smooth(duration: 0.3), value: phase)
        .animation(.smooth(duration: 0.3), value: isEditing)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Slot \(status.slot + 1), \(phase.label)")
        .accessibilityAddTraits(isEditing ? .isSelected : [])
    }

    private var tint: Color? {
        switch phase {
        case .done: .green.opacity(0.18)
        case .error: .red.opacity(0.22)
        case .preCharge, .constantCurrent, .charging, .constantVoltage: .blue.opacity(0.10)
        default: nil
        }
    }

    // MARK: Battery

    private var fraction: Double {
        switch phase {
        case .done: 1
        case .preCharge, .constantCurrent, .charging, .constantVoltage: Double(status.capacityPercent) / 100
        default: 0
        }
    }

    private var isBreathing: Bool { isLive && phase.isCharging }

    private var battery: some View {
        VStack(spacing: 3) {
            Capsule()
                .fill(phase.color.opacity(status.hasBattery ? 0.5 : 0.25))
                .frame(width: 18, height: 4)
            GeometryReader { geo in
                let cell = RoundedRectangle(cornerRadius: 14, style: .continuous)
                // Never shrink to an invisible sliver: a charging battery should look charging.
                let fillHeight = fraction > 0 ? max(geo.size.height * fraction, 8) : 0

                ZStack(alignment: .bottom) {
                    cell.fill(phase.color.opacity(status.hasBattery ? 0.14 : 0.06))
                    if fillHeight > 0 {
                        Rectangle()
                            .fill(phase.color.gradient)
                            .frame(height: fillHeight)
                    }
                    ZStack {
                        // Text over the empty part is drawn in normal colors, over the fill in white.
                        // Each layer is clipped to its own region, so a label that straddles the
                        // fill edge changes color exactly at the edge and stays readable.
                        labels(onFill: false, boltOnly: false)
                            .mask(alignment: .top) {
                                Rectangle().frame(height: max(geo.size.height - fillHeight, 0))
                            }
                        if fillHeight > 0 {
                            labels(onFill: true, boltOnly: false)
                                .mask(alignment: .bottom) {
                                    Rectangle().frame(height: fillHeight)
                                }
                        }
                        // The breathing bolt is its own layer (see BreathingBolt), laid out exactly
                        // like the text above so it lands in the same spot.
                        labels(onFill: fraction > 0.5, boltOnly: true)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.smooth(duration: 0.6), value: fillHeight)
                .clipShape(cell)
                .overlay {
                    cell.strokeBorder(
                        phase.color.opacity(status.hasBattery ? 0.35 : 0.3),
                        style: StrokeStyle(lineWidth: 1.5, dash: status.hasBattery ? [] : [3, 4]))
                }
            }
            .frame(maxWidth: 68)
        }
    }

    /// The contents of the battery: voltage on top, state glyph (+ current) in the middle, chemistry at the bottom.
    private func labels(onFill: Bool, boltOnly: Bool) -> some View {
        let strong: Color = onFill ? .white : .primary
        let soft: Color = onFill ? .white.opacity(0.85) : .secondary

        return VStack(spacing: 0) {
            Text(status.hasBattery ? Format.voltage(status.voltageMV) : " ")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(strong)
                .opacity(boltOnly ? 0 : 1)
                .padding(.top, 9)

            Spacer(minLength: 0)
            center(onFill: onFill, soft: soft, boltOnly: boltOnly)
            Spacer(minLength: 0)

            HStack(spacing: 3) {
                if hasUnappliedEdits {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
                Text(config?.batteryType.shortName ?? "—")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(soft)
            .opacity(boltOnly ? 0 : 1)
            .padding(.bottom, 9)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 3)
    }

    @ViewBuilder
    private func center(onFill: Bool, soft: Color, boltOnly: Bool) -> some View {
        switch phase {
        case .preCharge, .constantCurrent, .charging, .constantVoltage:
            VStack(spacing: 2) {
                if boltOnly {
                    BreathingBolt(color: onFill ? .white : NSColor(phase.color), breathing: isBreathing)
                        .frame(width: 20, height: 20)
                } else {
                    Color.clear.frame(width: 20, height: 20)
                }
                Text(Format.milliamps(status.currentMA))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(soft)
                    .opacity(boltOnly ? 0 : 1)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.title3.weight(.bold))
                .foregroundStyle(onFill ? Color.white : phase.color)
                .symbolEffect(.bounce, value: phase)
                .opacity(boltOnly ? 0 : 1)
        case .error:
            Image(systemName: "exclamationmark")
                .font(.title2.weight(.bold))
                .foregroundStyle(.red)
                .opacity(boltOnly ? 0 : 1)
        default:
            EmptyView()
        }
    }

    // MARK: Text

    private var headline: String {
        switch phase {
        case .preCharge, .constantCurrent, .charging, .constantVoltage: "\(status.capacityPercent)%"
        case .done: String(localized: "Done")
        case .error: String(localized: "Error")
        case .idle: String(localized: "Idle")
        case .empty: String(localized: "Empty")
        case .unknown(let raw): "#\(raw)"
        }
    }

    private var tooltip: String {
        var parts = [String(localized: "Slot \(status.slot + 1): \(phase.label)")]
        if status.hasBattery {
            parts.append("\(Format.voltage(status.voltageMV)), \(Format.milliampHours(status.chargedMAh))")
            if status.elapsed > 0 { parts.append(Format.elapsed(status.elapsed)) }
        }
        if let config { parts.append(Format.summary(config)) }
        return parts.joined(separator: " · ")
    }
}
