import ApplicationServices
import CoreGraphics
import Foundation

/// Turns `input` packets from the phone's touchpad screen into real mouse events.
/// Requires the Accessibility permission (macOS prompts on first use).
final class InputController {
    var onLog: ((String) -> Void)?

    private var dragging = false
    private var warnedAboutAccessibility = false

    func handle(_ body: [String: Any]) {
        guard let action = body["a"] as? String else { return }
        guard ensureTrusted() else { return }
        let dx = (body["dx"] as? Double) ?? 0
        let dy = (body["dy"] as? Double) ?? 0

        switch action {
        case "m":
            move(dx: dx, dy: dy)
        case "sc":
            scroll(dx: dx, dy: dy)
        case "c":
            click(body["b"] as? String ?? "l")
        case "dd":
            dragging = true
            postLeftButton(down: true)
        case "du":
            postLeftButton(down: false)
            dragging = false
        case "g":
            if let name = body["g"] as? String { gesture(name) }
        default:
            break
        }
    }

    /// Mac-trackpad-style gestures, mapped to the system shortcuts they trigger.
    private func gesture(_ name: String) {
        onLog?("Gesture from phone: \(name)")
        switch name {
        case "3left": keyCombo(124, .maskControl)      // swipe left → next Space (Ctrl+→)
        case "3right": keyCombo(123, .maskControl)     // swipe right → previous Space (Ctrl+←)
        case "3up": keyCombo(126, .maskControl)        // Mission Control (Ctrl+↑)
        case "3down": keyCombo(125, .maskControl)      // App Exposé (Ctrl+↓)
        case "pinchout": keyCombo(24, .maskCommand)    // zoom in (Cmd +)
        case "pinchin": keyCombo(27, .maskCommand)     // zoom out (Cmd −)
        case "4up": openLaunchpad()
        case "4down": keyCombo(103, [])                // show desktop (F11)
        default: break
        }
    }

    // Modifier key codes: Control = 59, Command = 55, Option = 58, Shift = 56.
    private func keyCombo(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Hold the modifier as a real key press — space switching (and many system
        // shortcuts) ignore a flag that isn't backed by an actual held modifier.
        let holdControl = flags.contains(.maskControl)
        let holdCommand = flags.contains(.maskCommand)
        if holdControl { postKey(59, down: true, flags: .maskControl, source: source) }
        if holdCommand { postKey(55, down: true, flags: flags, source: source) }

        postKey(keyCode, down: true, flags: flags, source: source)
        postKey(keyCode, down: false, flags: flags, source: source)

        if holdCommand { postKey(55, down: false, flags: [], source: source) }
        if holdControl { postKey(59, down: false, flags: [], source: source) }
    }

    private func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func openLaunchpad() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Launchpad"]
        try? process.run()
    }

    private func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !warnedAboutAccessibility {
            warnedAboutAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            onLog?("Touchpad needs Accessibility permission: System Settings → Privacy & Security → Accessibility → enable your terminal, then restart the app")
        }
        return false
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func move(dx: Double, dy: Double) {
        // Mild acceleration: slow finger = precise, fast finger = far.
        let speed = (dx * dx + dy * dy).squareRoot()
        let gain = 0.7 + min(2.3, speed / 20.0)

        var point = currentLocation()
        point.x += dx * gain
        point.y += dy * gain

        let bounds = CGDisplayBounds(CGMainDisplayID())
        point.x = max(bounds.minX, min(bounds.maxX - 1, point.x))
        point.y = max(bounds.minY, min(bounds.maxY - 1, point.y))

        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double) {
        // Natural direction: content follows the fingers, like on the phone screen.
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32((dy * 1.5).rounded()), wheel2: Int32((dx * 1.5).rounded()), wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    private func click(_ kind: String) {
        let point = currentLocation()
        let button: CGMouseButton
        let down: CGEventType
        let up: CGEventType
        switch kind {
        case "r":
            (button, down, up) = (.right, .rightMouseDown, .rightMouseUp)
        case "m":
            (button, down, up) = (.center, .otherMouseDown, .otherMouseUp)
        default:
            (button, down, up) = (.left, .leftMouseDown, .leftMouseUp)
        }
        CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private func postLeftButton(down: Bool) {
        let point = currentLocation()
        let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
