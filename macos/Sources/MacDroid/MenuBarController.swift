import AppKit
import ServiceManagement

/// Bifrost in the menu bar: a status-bar item with quick actions and a
/// launch-at-login toggle, so the app is one click away without the window.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private unowned let server: ServerManager
    private var batteryLevel: Int?
    private var batteryCharging = false

    init(server: ServerManager) {
        self.server = server
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.bifrostImage()
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private static func bifrostImage() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "Bifrost"
        )
        image?.isTemplate = true
        return image
    }

    // MARK: phone battery in the menu bar

    /// Show the phone's battery next to the Bifrost glyph: a tiered SF Symbols
    /// battery (bolt when charging) plus the percentage. `level == nil` hides it.
    func updateBattery(level: Int?, charging: Bool) {
        batteryLevel = level
        batteryCharging = charging
        guard let button = statusItem?.button else { return }
        guard let level else {
            button.image = Self.bifrostImage()
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = nil
            return
        }
        // One composed template image (arrows + battery glyph) — the menu bar
        // tints template images correctly in both light and dark appearances.
        let symbol = ServerManager.batterySymbol(level: level, charging: charging)
        if let arrows = Self.bifrostImage(),
           let battery = NSImage(systemSymbolName: symbol, accessibilityDescription: "Phone battery") {
            let gap: CGFloat = 5
            let size = NSSize(width: arrows.size.width + gap + battery.size.width,
                              height: max(arrows.size.height, battery.size.height))
            let composed = NSImage(size: size, flipped: false) { rect in
                arrows.draw(at: NSPoint(x: 0, y: (rect.height - arrows.size.height) / 2),
                            from: .zero, operation: .sourceOver, fraction: 1)
                battery.draw(at: NSPoint(x: arrows.size.width + gap,
                                         y: (rect.height - battery.size.height) / 2),
                             from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            composed.isTemplate = true
            button.image = composed
        }
        button.attributedTitle = NSAttributedString(
            string: " \(level)%",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
        )
        button.toolTip = "Phone battery: \(level)%\(charging ? " · charging" : "")"
    }

    // Rebuild the menu each time it opens so it reflects the live connection state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusText = server.isPaired
            ? "Connected · \(server.connectedDeviceName ?? "phone")"
            : "Not connected"
        let header = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if server.isPaired, let level = batteryLevel {
            let battery = NSMenuItem(
                title: "Battery · \(level)%\(batteryCharging ? " · charging" : "")",
                action: nil, keyEquivalent: ""
            )
            battery.isEnabled = false
            menu.addItem(battery)
        }

        if server.callState == "ringing" {
            let call = NSMenuItem(
                title: "Incoming call · \(server.callerDisplay.isEmpty ? "unknown" : server.callerDisplay)",
                action: nil, keyEquivalent: ""
            )
            call.isEnabled = false
            menu.addItem(call)
        }

        if server.callState == "offhook" {
            let call = NSMenuItem(
                title: "On call · \(server.callerDisplay.isEmpty ? "in progress" : server.callerDisplay)",
                action: nil, keyEquivalent: ""
            )
            call.isEnabled = false
            menu.addItem(call)
            menu.addItem(action("Hang up", #selector(hangUpCall)))
        }

        if let np = server.nowPlaying, np.playing {
            let track = NSMenuItem(title: "♪ \(np.title) — \(np.artist)", action: nil, keyEquivalent: "")
            track.isEnabled = false
            menu.addItem(track)
        }
        menu.addItem(.separator())

        if server.isPaired {
            menu.addItem(action("Send clipboard to phone", #selector(sendClipboard)))
            menu.addItem(action("Pull photos from phone…", #selector(pullPhotos)))
            menu.addItem(action("Open phone desktop", #selector(openDesktop)))
            menu.addItem(action("Ping phone", #selector(ping)))
            menu.addItem(.separator())
        }

        menu.addItem(action("Open Bifrost", #selector(showWindow)))
        let login = action("Launch at login", #selector(toggleLogin))
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("Quit Bifrost", #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func sendClipboard() { server.sendClipboardNow() }
    @objc private func pullPhotos() { server.pullPhotosFromPhone() }
    @objc private func openDesktop() { server.launchDesktopMode() }
    @objc private func ping() { server.pingPhone() }
    @objc private func hangUpCall() { server.callAction("hangup") }

    @objc private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: launch at login

    private var loginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            server.appendLogPublic("Launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
