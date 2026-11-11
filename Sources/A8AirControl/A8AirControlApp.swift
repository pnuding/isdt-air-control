import AppKit
import SwiftUI

/// One hub for the whole process; the delegate needs it before any scene exists.
@MainActor let sharedHub = ChargerHub()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { sharedHub.start() }
    }

    /// Closing the windows must not quit: the app keeps running in the menu bar
    /// so it can still tell you when a charge finishes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { sharedHub.shutdown() }
    }
}

@main
struct A8AirControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window per charger. Opened by the menu bar item (see MenuBarLabel), never at launch by itself.
        WindowGroup("Charger", id: "charger", for: UUID.self) { $id in
            ChargerWindow(id: id)
                .environment(sharedHub)
        }
        .defaultSize(width: 700, height: 380)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Adding, reconnecting and forgetting chargers.
        Window("Chargers", id: "chargers") {
            ChargersView()
                .environment(sharedHub)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent()
                .environment(sharedHub)
        } label: {
            MenuBarLabel()
                .environment(sharedHub)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        .commands { ChargerCommands() }
    }
}

/// SwiftUI would add File > New Window for the per-charger window group, but a charger window only
/// makes sense for a specific charger, so that item opened a window that closed itself at once.
/// Putting the Chargers window here instead gives the item a real job, and keeps the File menu
/// (and Close / ⌘W with it): SwiftUI drops the whole menu if this group is left empty.
struct ChargerCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Chargers…") {
                openWindow(id: "chargers")
                NSApp.activate()
            }
        }
    }
}

/// The window for one charger. If the charger is forgotten while its window is open, the window closes.
struct ChargerWindow: View {
    let id: UUID?
    @Environment(ChargerHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let id, let charger = hub.charger(id: id) {
            ContentView()
                .environment(charger)
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .task { dismiss() }
        }
    }
}
