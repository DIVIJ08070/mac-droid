import Foundation
import UserNotifications

/// Shows native macOS banner notifications mirrored from the phone, and lets the
/// user reply inline (the reply is sent back to the phone to fire its reply action).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized = false
    private var warnedDenied = false
    var onLog: ((String) -> Void)?
    /// Called when the user types a reply on a mirrored notification: (id, text).
    var onReply: ((String, String) -> Void)?

    private let replyCategoryID = "BIFROST_REPLY"

    /// UNUserNotificationCenter requires a real app bundle; it crashes when the
    /// binary is run directly (e.g. `swift run`). Guard on a bundle identifier.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // A category with an inline "Reply" text field, used for repliable notifications.
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY", title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message"
        )
        let category = UNNotificationCategory(
            identifier: replyCategoryID, actions: [replyAction],
            intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                if !granted { self?.onLog?("Mac notifications are OFF — enable Bifrost in System Settings → Notifications to see phone notifications pop up.") }
            }
        }
    }

    func show(app: String, title: String, body: String, id: String = "", canReply: Bool = false) {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                if settings.authorizationStatus != .authorized, !self.warnedDenied {
                    self.warnedDenied = true
                    self.onLog?("Banner blocked — turn on notifications for Bifrost: System Settings → Notifications → Bifrost → Allow Notifications (style: Banners).")
                }
            }
        }
        let content = UNMutableNotificationContent()
        if title.isEmpty {
            content.title = app
            content.body = body.isEmpty ? "New notification" : body
        } else {
            content.title = "\(app) · \(title)"
            content.body = body
        }
        content.sound = .default
        content.interruptionLevel = .active
        if canReply, !id.isEmpty {
            content.categoryIdentifier = replyCategoryID
            content.userInfo = ["id": id]
        }
        // Use the phone's notification id as the request identifier so updates to the
        // same conversation replace the banner instead of stacking, and so it can be
        // removed later when the phone dismisses it. Fall back to a UUID when empty.
        let identifier = id.isEmpty ? UUID().uuidString : id
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                Task { @MainActor in self?.onLog?("Notification error: \(error.localizedDescription)") }
            }
        }
    }

    /// Remove a mirrored banner after the phone dismisses/clears it.
    func dismiss(id: String) {
        guard available, !id.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Show the banner even when Bifrost itself is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// The user typed a reply on a mirrored notification → send it back to the phone.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let textResponse = response as? UNTextInputNotificationResponse,
           response.actionIdentifier == "REPLY",
           let id = response.notification.request.content.userInfo["id"] as? String {
            let text = textResponse.userText
            Task { @MainActor in self.onReply?(id, text) }
        }
        completionHandler()
    }
}
