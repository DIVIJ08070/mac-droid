import AppKit
import CoreGraphics

/// Universal-Control-style input for the phone: capture the Mac's mouse +
/// keyboard and drive a cursor on the phone — no mirror window. Enter by sliding
/// off the right screen edge or the hotkey ⌃⌥⌘; exit with the same hotkey.
///
/// Safety: the CONSUMING event tap exists ONLY while active, the exit hotkey is
/// checked inside the tap, and if the app crashes macOS releases the tap — so the
/// Mac's input can never be permanently trapped.
@MainActor
final class UniversalControl {
    /// (packetType, body) → put on the wire by ServerManager.
    var onSend: ((String, [String: Any]) -> Void)?
    var onLog: ((String) -> Void)?
    var onActiveChange: ((Bool) -> Void)?
    /// Gate entry on an actually-paired phone.
    var isPaired: () -> Bool = { false }

    private(set) var active = false
    var enabled = true
    var edgeSlideEnabled = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var savedPos = CGPoint.zero
    private var hotkeyMonitor: Any?
    private var edgeMonitor: Any?
    private var edgeArmed = true
    private var hotkeyLatched = false

    // Left-drag detection: while the button is held we accumulate the delta and
    // decide click-vs-drag on release, so a real drag becomes a swipe.
    private var leftDown = false
    private var accumDX = 0.0
    private var accumDY = 0.0
    private var movedWhileDown = false

    private let sensitivity = 1.0 // the phone scales by its density for consistent speed
    private let dragThreshold = 8.0

    // MARK: lifecycle

    /// Install the lightweight always-on monitors that let the user ENTER control
    /// mode (they don't consume events). The consuming tap is created only on enter.
    func start() {
        guard hotkeyMonitor == nil else { return }
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.enabled, !self.active else { return }
            Task { @MainActor in self.handleEnterHotkey(event.modifierFlags) }
        }
        edgeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, self.enabled, self.edgeSlideEnabled, !self.active, self.isPaired() else { return }
            Task { @MainActor in self.checkEdge() }
        }
    }

    func toggle() { active ? exit() : enter() }

    /// Called when the phone disconnects — never leave the tap consuming input.
    func exitIfActive() { if active { exit() } }

    // MARK: enter / exit

    private func handleEnterHotkey(_ flags: NSEvent.ModifierFlags) {
        let combo = flags.contains(.control) && flags.contains(.option) && flags.contains(.command)
        if combo && !hotkeyLatched { hotkeyLatched = true; enter() }
        else if !combo { hotkeyLatched = false }
    }

    private func checkEdge() {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }) ?? NSScreen.main
        else { return }
        // Only the RIGHTMOST display's right edge is the "slide to phone" edge —
        // otherwise the internal boundary between two displays would false-trigger.
        let rightmost = NSScreen.screens.map { $0.frame.maxX }.max() ?? screen.frame.maxX
        guard screen.frame.maxX >= rightmost - 0.5 else { edgeArmed = true; return }
        let maxX = screen.frame.maxX
        if loc.x >= maxX - 1.5 {
            if edgeArmed { edgeArmed = false; enter() }
        } else if loc.x < maxX - 40 {
            edgeArmed = true // re-arm once the cursor is clear of the edge
        }
    }

    private func enter() {
        guard enabled, !active, isPaired() else { return }
        guard AXIsProcessTrusted() else {
            onLog?("Universal Control needs Accessibility — enable Bifrost in System Settings → Privacy & Security → Accessibility")
            return
        }
        guard installTap() else {
            onLog?("Couldn't start Universal Control (event tap failed)")
            return
        }
        active = true
        savedPos = CGEvent(source: nil)?.location ?? .zero
        // Come frontmost so the cursor reliably hides (CGDisplayHideCursor is
        // scoped to the active app); NSCursor.hide adds a ref-counted fallback.
        NSApp.activate(ignoringOtherApps: true)
        CGAssociateMouseAndMouseCursorPosition(0) // decouple: read deltas, cursor stays put
        NSCursor.hide()
        CGDisplayHideCursor(CGMainDisplayID())
        leftDown = false; accumDX = 0; accumDY = 0; movedWhileDown = false
        onSend?("control.start", [:])
        onActiveChange?(true)
        onLog?("Controlling phone — press ⌃⌥⌘ to return to the Mac")
    }

    private func exit() {
        guard active else { return }
        active = false
        removeTap()
        CGAssociateMouseAndMouseCursorPosition(1)
        CGWarpMouseCursorPosition(savedPos)
        NSCursor.unhide()
        CGDisplayShowCursor(CGMainDisplayID())
        onSend?("control.stop", [:])
        onActiveChange?(false)
        onLog?("Back on the Mac")
    }

    // MARK: event tap

    private func installTap() -> Bool {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged,
        ]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: universalControlTapCallback, userInfo: ptr
        ) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; runLoopSource = nil
    }

    /// Runs on the main run loop (where the tap source is attached). Returns nil to
    /// consume the event (while active we consume everything except to re-enable).
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        guard active else { return Unmanaged.passUnretained(event) }

        switch type {
        case .flagsChanged:
            let f = event.flags
            let combo = f.contains(.maskControl) && f.contains(.maskAlternate) && f.contains(.maskCommand)
            if combo && !hotkeyLatched { hotkeyLatched = true; exit() }
            else if !combo { hotkeyLatched = false }

        case .mouseMoved, .leftMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX) * sensitivity
            let dy = event.getDoubleValueField(.mouseEventDeltaY) * sensitivity
            if leftDown {
                accumDX += dx; accumDY += dy
                if abs(accumDX) + abs(accumDY) > dragThreshold { movedWhileDown = true }
            }
            // Always move so the phone cursor tracks live (even during a drag);
            // the phone anchors the drag start at control.press and swipes to here.
            onSend?("control.move", ["dx": dx, "dy": dy])

        case .leftMouseDown:
            leftDown = true; accumDX = 0; accumDY = 0; movedWhileDown = false
            onSend?("control.press", [:])

        case .leftMouseUp:
            onSend?("control.release", ["drag": movedWhileDown])
            leftDown = false

        case .rightMouseUp:
            onSend?("control.click", ["button": "right"]) // long-press on the phone

        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1) * 12
            onSend?("control.scroll", ["dy": dy])

        case .keyDown:
            forwardKey(event)

        default:
            break // consume rightMouseDown / keyUp / anything else
        }
        return nil
    }

    private func forwardKey(_ event: CGEvent) {
        // Don't type Mac keyboard shortcuts (⌘…) onto the phone.
        if event.flags.contains(.maskCommand) { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Navigation / editing keys the phone understands as "special".
        let specials: [Int64: String] = [
            51: "backspace", 36: "enter", 76: "enter", 49: "space",
            48: "tab", 53: "back", // Esc → phone Back
        ]
        if let special = specials[keyCode] {
            onSend?("screen.key", ["special": special])
            return
        }
        // Otherwise send the produced character(s) — but drop non-printable output
        // (arrows, F-keys, etc. come through as control/private-use scalars that
        // would otherwise be inserted as garbage).
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let text = String(utf16CodeUnits: chars, count: length)
        let printable = text.unicodeScalars.contains {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }
        if printable { onSend?("screen.key", ["text": text]) }
    }
}

/// Top-level C callback — reconstructs the instance and hops onto the main actor
/// (the tap source lives on the main run loop, so we're already on that thread).
private func universalControlTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let uc = Unmanaged<UniversalControl>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { uc.handle(type: type, event: event) }
}
