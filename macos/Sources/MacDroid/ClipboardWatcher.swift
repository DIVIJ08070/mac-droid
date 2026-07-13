import AppKit
import Foundation

/// Polls NSPasteboard for changes (there is no notification API for the pasteboard).
final class ClipboardWatcher {
    var onChange: ((String) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoreNextChange = false

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Set the clipboard from a remote packet without echoing it back.
    func setClipboard(_ content: String) {
        ignoreNextChange = true
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        lastChangeCount = pb.changeCount
    }

    static func current() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if ignoreNextChange {
            ignoreNextChange = false
            return
        }
        if let content = pb.string(forType: .string) {
            onChange?(content)
        }
    }
}
