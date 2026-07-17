import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import UserNotifications

/// Watches the macOS permissions Bifrost's features depend on, so the UI can
/// show a warning badge next to any feature whose permission is missing.
/// Re-checks on a slow timer and whenever the app becomes active (i.e. right
/// after the user comes back from System Settings).
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    /// Phone → Mac control (touchpad, presenter, media keys) via CGEvent injection.
    @Published var accessibilityOK = true
    /// Mirror Mac screen / stream system audio / remote screenshots (ScreenCaptureKit).
    @Published var screenRecordingOK = true
    /// Phone notification banners on the Mac.
    @Published var notificationsOK = true
    /// Keyboard for Universal Control (event-tap keyboard capture needs this,
    /// separate from Accessibility which covers the mouse).
    @Published var inputMonitoringOK = true

    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        accessibilityOK = AXIsProcessTrusted()
        screenRecordingOK = CGPreflightScreenCaptureAccess()
        inputMonitoringOK = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        // UNUserNotificationCenter crashes without a real bundle (swift run).
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            // .notDetermined means the system prompt hasn't been answered yet —
            // don't badge that; the request fires at launch.
            let ok = settings.authorizationStatus != .denied
            Task { @MainActor in self?.notificationsOK = ok }
        }
    }

    // Deep links to the exact System Settings pane.
    static let accessibilityPane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenRecordingPane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let notificationsPane =
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    static let inputMonitoringPane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
}
