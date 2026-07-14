import Foundation
import UserNotifications

/// Shows native macOS notifications mirrored from the phone.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func show(app: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        // Put the app name in the title so you can tell where it's from.
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
}
