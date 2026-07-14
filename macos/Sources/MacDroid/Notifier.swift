import Foundation
import UserNotifications

/// Shows native macOS banner notifications mirrored from the phone.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized = false

    /// UNUserNotificationCenter requires a real app bundle; it crashes when the
    /// binary is run directly (e.g. `swift run`). Guard on a bundle identifier.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func show(app: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        if title.isEmpty {
            content.title = app
            content.body = body
        } else {
            content.title = "\(app) · \(title)"
            content.body = body
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Show the banner even when MacDroid itself is the active app (macOS would
    /// otherwise silently drop it into Notification Center).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
