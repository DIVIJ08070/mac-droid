import AppKit
import ServiceManagement

/// Bifrost in the menu bar: a status-bar item with quick actions and a
/// launch-at-login toggle, so the app is one click away without the window.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private unowned let server: ServerManager

    init(server: ServerManager) {
        self.server = server
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "arrow.left.arrow.right",
                accessibilityDescription: "Bifrost"
            )
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
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
