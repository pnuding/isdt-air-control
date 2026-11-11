import Foundation
@preconcurrency import UserNotifications

/// System notifications for finished charges.
///
/// UNUserNotificationCenter traps when the process isn't an app bundle (e.g.
/// `swift run`), so everything here degrades to a no-op in that case.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// False when running outside a .app bundle (notifications can't work there).
    let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

    private override init() {
        super.init()
        if isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for permission the first time; afterwards just reports the current answer.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    func post(title: String, body: String, identifier: String, playSound: Bool) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "charging"
        if playSound { content.sound = .default }
        // nil trigger = deliver immediately.
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show the banner even while the app is frontmost; a finished charge is worth knowing about either way.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
