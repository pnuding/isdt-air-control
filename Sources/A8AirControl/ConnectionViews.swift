import ISDTCore
import SwiftUI

/// The Chargers window: the chargers this Mac knows, and the ones in range that can be added.
struct ChargersView: View {
    @Environment(ChargerHub.self) private var hub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let message = unavailableMessage {
                BluetoothUnavailableView(message: message, canOpenSettings: hub.radio == .unauthorized)
            } else {
                if !hub.chargers.isEmpty {
                    section("Your Chargers") {
                        ForEach(hub.chargers) { charger in
                            ownedRow(charger)
                        }
                    }
                }
                section(hub.chargers.isEmpty ? "Choose a charger" : "Nearby") {
                    nearbySection
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hub.beginScanning() }
        .onDisappear { hub.endScanning() }
    }

    private var unavailableMessage: String? {
        switch hub.radio {
        case .poweredOff: String(localized: "Bluetooth is turned off.")
        case .unauthorized: String(localized: "Bluetooth access is denied. Allow it for this app in System Settings → Privacy & Security → Bluetooth.")
        case .unsupported: String(localized: "This Mac doesn't support Bluetooth Low Energy.")
        default: nil
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    // MARK: Chargers you have

    private func ownedRow(_ charger: Charger) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol(charger))
                .foregroundStyle(statusColor(charger))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(charger.name).font(.headline)
                Text(statusText(charger)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Window") {
                openWindow(id: "charger", value: charger.id)
                NSApp.activate()
            }
            .buttonStyle(.glass)
            Menu {
                Button("Reconnect") { charger.reconnect() }
                Button("Forget Charger", role: .destructive) { hub.forget(charger) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }

    private func statusText(_ charger: Charger) -> String {
        switch charger.link {
        case .connected:
            charger.chargingCount > 0 ? String(localized: "Connected · \(charger.chargingCount) charging") : String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .pairing: String(localized: "Press any button on the charger to allow this Mac")
        case .retrying: String(localized: "Reconnecting…")
        case .bluetoothUnavailable(let message): message
        }
    }

    private func statusSymbol(_ charger: Charger) -> String {
        switch charger.link {
        case .connected: "checkmark.circle.fill"
        case .pairing: "hand.tap.fill"
        case .bluetoothUnavailable: "exclamationmark.triangle.fill"
        default: "circle.dotted"
        }
    }

    private func statusColor(_ charger: Charger) -> Color {
        switch charger.link {
        case .connected: .green
        case .pairing: .blue
        case .bluetoothUnavailable, .retrying: .orange
        case .connecting: .secondary
        }
    }

    // MARK: In range

    @ViewBuilder
    private var nearbySection: some View {
        if hub.nearby.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(hub.chargers.isEmpty ? String(localized: "Looking for chargers…") : String(localized: "Looking for more chargers…"))
                        .foregroundStyle(.secondary)
                }
                Text("Switch the charger on and keep it close to this Mac. A charger only talks to one app at a time, so close ISD Link on your phone first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(hub.nearby) { device in
                nearbyRow(device)
            }
        }
    }

    private func nearbyRow(_ device: DiscoveredCharger) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cellularbars", variableValue: min(max(Double(device.rssi + 95) / 50, 0.05), 1))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.kind?.displayName ?? device.modelName).font(.headline)
                Text(device.isSupported ? String(localized: "Ready to add") : String(localized: "Not supported"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") { hub.add(device) }
                .buttonStyle(.glassProminent)
                .disabled(!device.isSupported)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }
}

struct BluetoothUnavailableView: View {
    let message: String
    var canOpenSettings = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Bluetooth Unavailable").font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if canOpenSettings {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Thin status strip above the slots while the link isn't up.
struct ConnectionBanner: View {
    @Environment(Charger.self) private var charger

    var body: some View {
        if let content {
            HStack(spacing: 10) {
                if content.spinner {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: content.symbol).foregroundStyle(content.tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title).font(.callout.weight(.semibold))
                    if let detail = content.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if content.canRetry {
                    Button("Retry Now") { charger.reconnect() }
                        .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCard(.regular.tint(content.tint.opacity(0.15)), in: .rect(cornerRadius: 18))
        }
    }

    private struct Content {
        var title: LocalizedStringKey
        var detail: String?
        var symbol = "exclamationmark.triangle.fill"
        var tint: Color = .orange
        var spinner = false
        var canRetry = false
    }

    private var content: Content? {
        switch charger.link {
        case .connecting:
            Content(title: "Connecting to \(charger.name)…", tint: .blue, spinner: true)
        case .pairing:
            Content(title: "Press any button on the charger",
                    detail: String(localized: "It's waiting for you to allow this Mac. You only need to do this once."),
                    symbol: "hand.tap.fill", tint: .blue)
        case .retrying(let reason):
            Content(title: "Connection lost — reconnecting", detail: reason, canRetry: true)
        case .bluetoothUnavailable(let message):
            Content(title: "Bluetooth unavailable", detail: message, symbol: "antenna.radiowaves.left.and.right.slash")
        case .connected:
            nil
        }
    }
}
