import AppKit
import ISDTCore
import SwiftUI

struct ContentView: View {
    @Environment(Charger.self) private var charger

    /// Narrow enough for a 2-slot C4, wide enough that 8 columns never get cramped.
    private var minWidth: CGFloat { max(360, CGFloat(charger.visibleSlots.count) * 76 + 50) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceHeader()
            ConnectionBanner()
            SlotRowView()
        }
        .padding(20)
        .background { Backdrop() }
        .navigationTitle(charger.name)
        .navigationSubtitle(subtitle)
        // Width is free; height always hugs the content, so there's no dead space under the slots.
        .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        // A focused text field would otherwise swallow the first click on a slot.
        .onTapGesture { NSApp.keyWindow?.resignFirstResponderIfEditingText() }
    }

    private var subtitle: String {
        switch charger.link {
        case .connected:
            if charger.chargingCount > 0 { return String(localized: "\(charger.chargingCount) charging") }
            return charger.doneCount > 0 ? String(localized: "\(charger.doneCount) done") : String(localized: "Connected")
        case .connecting: return String(localized: "Connecting…")
        case .pairing: return String(localized: "Waiting for pairing")
        case .retrying: return String(localized: "Reconnecting…")
        case .bluetoothUnavailable: return String(localized: "Bluetooth unavailable")
        }
    }
}

/// The slots side by side, in the charger's physical order. Clicking one opens its settings.
struct SlotRowView: View {
    @Environment(Charger.self) private var charger

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(charger.visibleSlots, id: \.self) { slot in
                    let status = charger.slots[slot]
                    SlotColumnView(
                        status: status,
                        config: charger.deviceConfigs[slot],
                        isEditing: charger.editingSlot == slot,
                        hasUnappliedEdits: charger.dirty.contains(slot),
                        isLive: charger.link == .connected
                    )
                    // Few slots (a C4 using its two large bays) shouldn't stretch into huge cards.
                    .frame(maxWidth: 120)
                    .onTapGesture { charger.editingSlot = slot }
                    .popover(isPresented: Binding(
                        get: { charger.editingSlot == slot },
                        set: { if !$0, charger.editingSlot == slot { charger.editingSlot = nil } }
                    ), arrowEdge: .bottom) {
                        SlotEditorView()
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Header

struct DeviceHeader: View {
    @Environment(Charger.self) private var charger

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(charger.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                if let hw = charger.hardware {
                    Text("Firmware \(hw.firmwareVersion) · Hardware \(hw.hardwareVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let mV = charger.inputMillivolts, let mA = charger.inputMilliamps {
                Label {
                    Text(String(format: "%.2f V · %.2f A", Double(mV) / 1000, Double(mA) / 1000))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "powerplug.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(charger.link == .connected ? 1 : 0.5)
            }
        }
    }
}

/// A faint wash of colour behind the glass so it has something to refract.
private struct Backdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color.blue.opacity(0.10), Color.purple.opacity(0.06), Color.clear],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
