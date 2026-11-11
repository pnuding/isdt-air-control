import AppKit
import ISDTCore
import SwiftUI

/// Menu bar icon: a battery that gains a bolt while anything is charging.
///
/// This view is also the app's window opener. The menu bar item is the one view that always
/// exists (even with every window closed), so it watches the hub for window requests.
struct MenuBarLabel: View {
    @Environment(ChargerHub.self) private var hub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if hub.chargingCount > 0 {
                Label("\(hub.chargingCount)", systemImage: "bolt.batteryblock.fill")
            } else {
                Image(systemName: hub.doneCount > 0 ? "checkmark.circle" : "batteryblock")
            }
        }
        .task(id: hub.windowRequests) {
            let ids = hub.windowRequests
            guard !ids.isEmpty else { return }
            hub.windowRequests.removeAll()
            for id in ids { openWindow(id: "charger", value: id) }
            NSApp.activate()
        }
        .task(id: hub.chargersWindowRequests) {
            guard hub.chargersWindowRequests > 0 else { return }
            openWindow(id: "chargers")
            NSApp.activate()
        }
    }
}

/// Compact overview of every charger, so you can check on a charge without opening a window.
struct MenuBarContent: View {
    @Environment(ChargerHub.self) private var hub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hub.chargers.isEmpty {
                Text("No chargers yet").font(.headline)
                Text("Add one to see its slots here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(hub.chargers) { charger in
                ChargerSummary(charger: charger)
            }

            Divider()

            HStack {
                Button("Chargers…") {
                    openWindow(id: "chargers")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

private struct ChargerSummary: View {
    let charger: Charger
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(charger.name).font(.headline)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Button {
                    openWindow(id: "charger", value: charger.id)
                    NSApp.activate()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Open window")
            }

            VStack(spacing: 3) {
                ForEach(charger.visibleStatuses) { slot in
                    HStack(spacing: 8) {
                        Image(systemName: slot.phase.symbol)
                            .foregroundStyle(slot.phase.color)
                            .frame(width: 18)
                        Text(slot.phase.label)
                        Spacer()
                        if slot.hasBattery {
                            Text(slot.phase == .done ? Format.voltage(slot.voltageMV) : "\(slot.capacityPercent)%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            .opacity(charger.link == .connected ? 1 : 0.5)
        }
    }

    private var statusText: String {
        switch charger.link {
        case .connected: charger.chargingCount > 0 ? String(localized: "\(charger.chargingCount) charging") : String(localized: "Connected")
        case .connecting, .pairing: String(localized: "Connecting…")
        case .retrying: String(localized: "Reconnecting…")
        case .bluetoothUnavailable: String(localized: "No Bluetooth")
        }
    }
}
