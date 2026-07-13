import AppKit
import SwiftUI

@main
struct MacDroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var server = ServerManager()

    var body: some Scene {
        WindowGroup("MacDroid") {
            ContentView()
                .environmentObject(server)
                .onAppear { server.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SPM executable: promote to a regular app with a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
