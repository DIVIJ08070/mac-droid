import Foundation
import UserNotifications

/// Shows native macOS banner notifications mirrored from the phone, and lets the
/// user reply inline (the reply is sent back to the phone to fire its reply action),
/// fire the notification's own action buttons, dismiss it on the phone, and act on
/// incoming calls (Silence/Decline) from a high-priority call banner.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized = false
    private var warnedDenied = false
    var onLog: ((String) -> Void)?
    /// Called when the user types a reply on a mirrored notification: (id, text).
    var onReply: ((String, String) -> Void)?
    /// Called when the user clicks a mirrored action button: (sbn key, action index).
    var onAction: ((String, Int) -> Void)?
    /// Called when the user clicks Dismiss on a mirrored banner: (sbn key).
    var onDismissAction: ((String) -> Void)?
    /// Called from the incoming-call banner: "silence" or "decline".
    var onCallAction: ((String) -> Void)?

    private let replyCategoryID = "BIFROST_REPLY"
    private let callCategoryID = "BIFROST_CALL"
    private let callRequestID = "bifrost.call"

    /// Static categories (reply, call) registered once at startup.
    private var baseCategories: Set<UNNotificationCategory> = []
    /// Rolling per-notification categories so action button titles are correct.
    /// Newest last; capped so the registered set can't grow without bound.
    private var dynamicCategories: [UNNotificationCategory] = []
    private let maxDynamicCategories = 24

    /// The inline-reply text action shared by the static reply category and the
    /// dynamic per-notification categories.
    private static func makeReplyAction() -> UNTextInputNotificationAction {
        UNTextInputNotificationAction(
            identifier: "REPLY", title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message"
        )
    }

    private func pushCategories() {
        UNUserNotificationCenter.current()
            .setNotificationCategories(baseCategories.union(dynamicCategories))
    }

    /// UNUserNotificationCenter requires a real app bundle; it crashes when the
    /// binary is run directly (e.g. `swift run`). Guard on a bundle identifier.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // A category with an inline "Reply" text field, used for repliable notifications.
        let category = UNNotificationCategory(
            identifier: replyCategoryID, actions: [Self.makeReplyAction()],
            intentIdentifiers: [], options: []
        )
        // Incoming-call banner: Silence + Decline, relayed to the phone.
        let callCategory = UNNotificationCategory(
            identifier: callCategoryID,
            actions: [
                UNNotificationAction(identifier: "SILENCE", title: "Silence", options: []),
                UNNotificationAction(identifier: "DECLINE", title: "Decline", options: [.destructive]),
            ],
            intentIdentifiers: [], options: []
        )
        baseCategories = [category, callCategory]
        pushCategories()

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
                if !granted { self?.onLog?("Mac notifications are OFF — enable Bifrost in System Settings → Notifications to see phone notifications pop up.") }
            }
        }
    }

    func show(app: String, title: String, body: String, id: String = "", canReply: Bool = false,
              key: String = "", actions: [String] = []) {
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
        if !key.isEmpty {
            // A dynamic category per notification carries the phone's own action
            // titles (max 3) plus Dismiss — and inline Reply when supported.
            content.categoryIdentifier = registerDynamicCategory(key: key, canReply: canReply, actions: actions)
            content.userInfo = ["id": id, "key": key]
        } else if canReply, !id.isEmpty {
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

    /// Build (or refresh) the per-notification category so the banner's buttons
    /// show the phone's real action titles. Returns the category identifier.
    private func registerDynamicCategory(key: String, canReply: Bool, actions: [String]) -> String {
        let categoryID = "BIFROST_N_" + key
        var categoryActions: [UNNotificationAction] = []
        if canReply { categoryActions.append(Self.makeReplyAction()) }
        for (index, title) in actions.prefix(3).enumerated() {
            categoryActions.append(
                UNNotificationAction(identifier: "ACT_\(index)", title: title, options: [])
            )
        }
        categoryActions.append(
            UNNotificationAction(identifier: "DISMISS", title: "Dismiss on phone", options: [.destructive])
        )
        let category = UNNotificationCategory(
            identifier: categoryID, actions: categoryActions,
            intentIdentifiers: [], options: []
        )
        dynamicCategories.removeAll { $0.identifier == categoryID }
        dynamicCategories.append(category)
        if dynamicCategories.count > maxDynamicCategories {
            dynamicCategories.removeFirst(dynamicCategories.count - maxDynamicCategories)
        }
        pushCategories()
        return categoryID
    }

    // MARK: Incoming-call banner

    /// High-priority banner for a ringing phone: caller + Silence/Decline buttons.
    func showCall(name: String, number: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        let caller = name.isEmpty ? (number.isEmpty ? "Unknown caller" : number) : name
        content.title = "Incoming call · \(caller)"
        if !name.isEmpty, !number.isEmpty { content.body = number }
        content.sound = .default
        content.categoryIdentifier = callCategoryID
        content.interruptionLevel = .timeSensitive
        let requestID = callRequestID
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error != nil else { return }
            // Time-sensitive needs an entitlement some builds don't have — retry
            // at the normal level rather than dropping the banner.
            content.interruptionLevel = .active
            let retry = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(retry) { [weak self] retryError in
                if let retryError {
                    Task { @MainActor in self?.onLog?("Call banner error: \(retryError.localizedDescription)") }
                }
            }
        }
    }

    /// Clear the call banner when the ring ends (answered, declined or missed).
    func dismissCall() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [callRequestID])
        center.removePendingNotificationRequests(withIdentifiers: [callRequestID])
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
        let userInfo = response.notification.request.content.userInfo
        if let textResponse = response as? UNTextInputNotificationResponse,
           response.actionIdentifier == "REPLY",
           let id = userInfo["id"] as? String {
            let text = textResponse.userText
            Task { @MainActor in self.onReply?(id, text) }
        } else if response.actionIdentifier.hasPrefix("ACT_"),
                  let index = Int(response.actionIdentifier.dropFirst(4)),
                  let key = userInfo["key"] as? String {
            // A mirrored action button → fire that action's PendingIntent on the phone.
            Task { @MainActor in self.onAction?(key, index) }
        } else if response.actionIdentifier == "DISMISS",
                  let key = userInfo["key"] as? String {
            Task { @MainActor in self.onDismissAction?(key) }
        } else if response.actionIdentifier == "SILENCE" {
            Task { @MainActor in self.onCallAction?("silence") }
        } else if response.actionIdentifier == "DECLINE" {
            Task { @MainActor in self.onCallAction?("decline") }
        }
        completionHandler()
    }
}
