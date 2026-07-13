import AppKit
import Foundation

/// Handoff-style menu bar item: shows the page currently open in the phone's
/// browser; clicking it opens that page on the Mac.
@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var currentURL: String?

    func show(url: String, title: String) {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(
                systemSymbolName: "iphone.gen3.badge.play",
                accessibilityDescription: "Page open on phone"
            ) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Page open on phone")
            item.button?.imagePosition = .imageLeading
            item.button?.action = #selector(openCurrentURL)
            item.button?.target = self
            statusItem = item
        }
        currentURL = url

        let label = title.isEmpty ? (URL(string: url)?.host ?? url) : title
        statusItem?.button?.title = " " + String(label.prefix(28))
        statusItem?.button?.toolTip = "Open on this Mac:\n\(url)"
    }

    func hide() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        currentURL = nil
    }

    @objc private func openCurrentURL() {
        guard let currentURL, let url = URL(string: currentURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
