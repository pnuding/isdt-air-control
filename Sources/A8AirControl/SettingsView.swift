import AppKit
@preconcurrency import UserNotifications
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.notifyOnDone) private var notifyOnDone = true
    @AppStorage(Pref.notifyOnError) private var notifyOnError = true
    @AppStorage(Pref.notificationSound) private var notificationSound = true
    @AppStorage(Pref.pollInterval) private var pollInterval = 3.0

    /// nil until macOS has answered, so the permission row doesn't flash up for a moment.
    @State private var authorization: UNAuthorizationStatus?

    private var needsPermission: Bool {
        switch authorization {
        case .none, .authorized, .provisional, .ephemeral: false
        default: true
        }
    }

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("When a slot finishes charging", isOn: $notifyOnDone)
                Toggle("When a slot reports an error", isOn: $notifyOnError)
                Toggle("Play a sound", isOn: $notificationSound)

                // Only shown while we don't have permission.
                if needsPermission {
                    LabeledContent("System permission") {
                        Text(authorization == .denied ? String(localized: "Denied in System Settings") : String(localized: "Not asked yet"))
                            .foregroundStyle(.orange)
                    }
                    if authorization == .notDetermined {
                        Button("Allow Notifications") {
                            Task {
                                await NotificationManager.shared.requestAuthorization()
                                await refreshAuthorization()
                            }
                        }
                    } else {
                        Button("Open Notification Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
                if !NotificationManager.shared.isAvailable {
                    Text("Notifications only work from the built app bundle, not when launched with swift run.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Updates") {
                LabeledContent("Refresh every") {
                    HStack {
                        Slider(value: $pollInterval, in: 1...10, step: 1)
                            .frame(width: 140)
                        Text("\(Int(pollInterval)) s")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refreshAuthorization() }
        // Coming back from System Settings after granting permission.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private func refreshAuthorization() async {
        authorization = await NotificationManager.shared.authorizationStatus()
    }
}
