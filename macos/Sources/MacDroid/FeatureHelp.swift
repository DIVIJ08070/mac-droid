import AppKit
import SwiftUI

// MARK: - Feature help: every card gets a small "?" that opens a full guide.
// Content lives here as data; HelpButton/popover render it in the app's dark
// monospace style. Permission warnings reuse the same popover treatment so a
// user can always discover WHY a ⚠ badge is showing and fix it in one click.

// MARK: Model

/// One permission a feature depends on — macOS (with a System Settings deep
/// link + live status) or phone-side (explains where on the phone to grant it).
struct HelpPermission: Identifiable {
    let id = UUID()
    let name: String
    /// Why the feature needs this permission.
    let why: String
    /// Exactly what stops working — always spells out
    /// "will not work until you grant …".
    let blocks: String
    /// How to grant it, in words.
    let howToGrant: String
    /// Deep link to the exact System Settings pane (nil = phone-side permission).
    let pane: String?
    /// Live check against PermissionMonitor (nil = phone-side permission).
    let granted: KeyPath<PermissionMonitor, Bool>?
}

/// Everything the "?" popover shows for one feature.
struct FeatureHelp {
    let title: String
    let icon: String
    /// "What it does" paragraph.
    let what: String
    /// "How to use" — numbered steps.
    let steps: [String]
    /// Permissions the feature needs (empty = none).
    let permissions: [HelpPermission]
    /// "If it doesn't work" paragraph.
    let troubleshooting: String
}

// MARK: - Help button ("?" in a circle, like the intro button, scaled to fit a card header)

struct HelpButton: View {
    let help: FeatureHelp
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("How \(help.title) works — click for the full guide")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            FeatureHelpPopover(help: help)
        }
    }
}

// MARK: - Feature guide popover

struct FeatureHelpPopover: View {
    let help: FeatureHelp
    @ObservedObject private var perms = PermissionMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: help.icon)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.dim)
                    Text(help.title.uppercased())
                        .font(Theme.mono(11, .semibold))
                        .tracking(3)
                        .foregroundStyle(.white)
                }

                helpSection("What it does") {
                    bodyText(help.what)
                }

                helpSection("How to use") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(help.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(format: "%02d", index + 1))
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.faint)
                                bodyText(step)
                            }
                        }
                    }
                }

                helpSection("Permissions") {
                    if help.permissions.isEmpty {
                        bodyText("None. This feature needs no macOS permissions.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(help.permissions) { permission in
                                permissionBlock(permission)
                            }
                        }
                    }
                }

                helpSection("If it doesn't work") {
                    bodyText(help.troubleshooting)
                }
            }
            .padding(18)
            .frame(width: 360, alignment: .leading)
        }
        .frame(width: 360)
        .frame(maxHeight: 460)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func permissionBlock(_ permission: HelpPermission) -> some View {
        let granted = permission.granted.map { perms[keyPath: $0] }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let granted {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(granted ? Color(red: 0.45, green: 0.95, blue: 0.6) : .orange)
                }
                Text(permission.name)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(.white)
                if let granted {
                    Text(granted ? "granted" : "missing")
                        .font(Theme.mono(9))
                        .tracking(1)
                        .foregroundStyle(granted ? Theme.faint : .orange)
                }
            }
            bodyText(permission.why)
            if granted != true {
                Text(permission.blocks)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(permission.howToGrant)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let pane = permission.pane, granted != true {
                Button("Open System Settings") {
                    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, size: 10))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            content()
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.dim)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Permission warning badge/chip → same popover treatment

/// Explains one missing permission: why the ⚠ is there, exactly what won't
/// work until it's granted, and a button to the right System Settings pane.
struct PermissionHelpPopover: View {
    let info: HelpPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("\(info.name) — missing".uppercased())
                    .font(Theme.mono(10, .semibold))
                    .tracking(2)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Why this warning")
                popText(info.why, color: Theme.dim)
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("What stops working")
                popText(info.blocks, color: Color.orange.opacity(0.85))
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("How to fix it")
                popText(info.howToGrant, color: Theme.dim)
                if let pane = info.pane {
                    Button("Open System Settings") {
                        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: 11))
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private func popText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(color)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Icon-only ⚠ next to a feature header. Hover explains in one line; click
/// opens the full explanation with an Open System Settings button.
struct PermissionWarningBadge: View {
    let info: HelpPermission
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
        .buttonStyle(.plain)
        .help("\(info.name) permission is missing — this feature will not work until you grant it. Click for details.")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PermissionHelpPopover(info: info)
        }
    }
}

/// Labeled ⚠ chip for permissions whose features are phone-driven (no Mac card).
struct PermissionWarningChip: View {
    let info: HelpPermission
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text("\(info.name) permission needed")
                    .font(Theme.mono(10))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(info.name) permission is missing — \(info.blocks) Click for details.")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PermissionHelpPopover(info: info)
        }
    }
}

// MARK: - Permission content (macOS + phone-side)

@MainActor
extension HelpPermission {
    static let screenRecording = HelpPermission(
        name: "Screen Recording",
        why: "macOS gates both screen capture AND system-audio capture behind the Screen Recording permission (ScreenCaptureKit). Bifrost never records anything to disk — frames and audio stream straight to your phone, encrypted.",
        blocks: "\"Stream Mac audio to phone\", \"Mirror Mac to phone\" and remote screenshots will not work until you grant Screen Recording.",
        howToGrant: "System Settings → Privacy & Security → Screen Recording → turn on Bifrost. macOS may ask you to quit & reopen the app afterwards.",
        pane: PermissionMonitor.screenRecordingPane,
        granted: \.screenRecordingOK
    )

    static let accessibility = HelpPermission(
        name: "Accessibility",
        why: "The phone's touchpad, presentation clicker and media keys control this Mac by injecting real keyboard/mouse events (CGEvent) — macOS only allows that for apps with the Accessibility permission.",
        blocks: "The phone-side touchpad/remote control, presentation clicker (→ ← B F5 Esc) and media keys will not work until you grant Accessibility.",
        howToGrant: "System Settings → Privacy & Security → Accessibility → turn on Bifrost.",
        pane: PermissionMonitor.accessibilityPane,
        granted: \.accessibilityOK
    )

    static let notifications = HelpPermission(
        name: "Notifications",
        why: "Bifrost mirrors your phone's notifications as native macOS banners (with inline reply where the app supports it) — macOS only shows them if Bifrost is allowed to post notifications.",
        blocks: "Phone notifications will not pop up on this Mac until you allow notifications for Bifrost.",
        howToGrant: "System Settings → Notifications → Bifrost → Allow notifications, style Banners or Alerts.",
        pane: PermissionMonitor.notificationsPane,
        granted: \.notificationsOK
    )

    static let inputMonitoring = HelpPermission(
        name: "Input Monitoring",
        why: "Universal Control types on your phone by capturing the Mac's keyboard through an event tap. macOS gates keyboard capture behind Input Monitoring — separate from Accessibility, which only covers the mouse. That's why the cursor moves but typing doesn't until you grant this.",
        blocks: "Typing on the phone during Universal Control will not work until you grant Input Monitoring (the cursor still works without it).",
        howToGrant: "System Settings → Privacy & Security → Input Monitoring → turn on Bifrost, then re-enter control.",
        pane: PermissionMonitor.inputMonitoringPane,
        granted: \.inputMonitoringOK
    )

    static let phoneWirelessDebug = HelpPermission(
        name: "Wireless debugging (on the phone)",
        why: "Desktop Mode drives the phone over ADB, Android's developer bridge. Android only allows that after you enable Developer options and turn on Wireless debugging (or plain USB debugging over a cable).",
        blocks: "Desktop Mode will not work until Wireless debugging (or USB debugging with a cable) is enabled on the phone.",
        howToGrant: "Phone: Settings → About phone → tap \"Build number\" 7× → back → Developer options → Wireless debugging ON. The in-app Setup guide checks this live.",
        pane: nil,
        granted: nil
    )

    static let phoneNotificationAccess = HelpPermission(
        name: "Notification access (on the phone)",
        why: "Mirroring notifications — and firing their action buttons or dismissing them from this Mac — requires Android's Notification access for Bifrost on the phone.",
        blocks: "Notification mirroring, action buttons and Dismiss from this Mac will not work until you grant Notification access on the phone.",
        howToGrant: "On the phone, Bifrost shows a permission badge with a grant button — tap it, or go to Settings → Notifications → Notification access → allow Bifrost.",
        pane: nil,
        granted: nil
    )

    static let phoneCallAccess = HelpPermission(
        name: "Phone & call permissions (on the phone)",
        why: "Detecting a ringing call needs Android's Phone permission; showing the number needs Call log; the caller's name needs Contacts; Decline and Hang up need Answer calls; Silence needs Do Not Disturb access to change the ringer. Mute and Speaker during a call are best-effort — the phone honors them when Android allows it.",
        blocks: "The incoming-call banner (Silence/Decline) and the on-call controls (Hang up/Mute/Speaker) will not work until the phone-side permissions are granted.",
        howToGrant: "On the phone, Bifrost shows a permission badge with grant buttons for each of these — tap through them once and the call banner starts working.",
        pane: nil,
        granted: nil
    )

    static let phoneAllFiles = HelpPermission(
        name: "All files access (on the phone)",
        why: "Browsing the phone's storage from this Mac requires Android's \"All files access\" permission for Bifrost on the phone.",
        blocks: "\"Browse phone files\" will not work until you grant All files access on the phone.",
        howToGrant: "Click \"Browse phone files\" once — the phone opens the right Settings screen automatically. Allow it there, then click Browse again.",
        pane: nil,
        granted: nil
    )
}

// MARK: - Feature content (facts match the implementation — keep in sync)

@MainActor
extension FeatureHelp {
    static let connection = FeatureHelp(
        title: "Connection",
        icon: "antenna.radiowaves.left.and.right",
        what: "Your phone and this Mac talk directly over an end-to-end encrypted link on port 52377 — no cloud, no account. The Mac advertises itself on the local network so the phone finds it by name. Pairing is one-time: confirm a 6-digit code once and the phone is remembered for silent reconnects.",
        steps: [
            "Same Wi-Fi: open Bifrost on the phone — this Mac appears by name. Tap it.",
            "Phone hotspot (no router needed): turn on the phone's hotspot, join it from the Mac's Wi-Fi menu — discovery works exactly the same.",
            "USB cable (no network at all): plug in, enable USB debugging on the phone (Settings → Developer options), then click \"Set up the USB link\". Bifrost creates an ADB reverse tunnel so the phone reaches this Mac at 127.0.0.1:52377. An already-paired phone reconnects by itself within ~10 s; first time, use Connect by address → 127.0.0.1:52377 on the phone.",
            "Tailscale (from anywhere): with Tailscale on both devices, use Connect by address on the phone → this Mac's Tailscale IP, port 52377.",
            "First connection shows the same 6-digit code on both screens — check they match, press Accept. Done: the phone reconnects silently from then on.",
        ],
        permissions: [],
        troubleshooting: "Phone can't find the Mac? Make sure both are on the same network (or the phone's hotspot) and check the status line and Activity log. USB link says \"no phone over ADB\"? Re-plug the cable, confirm USB debugging is ON, click the button again."
    )

    static let desktopMode = FeatureHelp(
        title: "Desktop Mode",
        icon: "macwindow.on.rectangle",
        what: "Opens a full Android desktop — powered by your phone — in its own window on this Mac, rendered by scrcpy on a separate virtual display over ADB. Your apps run on that virtual screen, so the phone itself stays free to use. Nothing extra is installed on the phone.",
        steps: [
            "One-time setup: click \"Setup guide\" — it checks every step live.",
            "Install the desktop engine (scrcpy, free & open source). Bifrost installs it for you via Homebrew (\"brew install scrcpy\"), plus ADB platform-tools if needed.",
            "On the phone: enable Developer options (tap Build number 7×), then turn on Wireless debugging — same Wi-Fi or the phone's hotspot. With a USB cable, plain USB debugging is enough.",
            "Pair once: on the phone open Wireless debugging → \"Pair device with pairing code\" — Bifrost spots the phone automatically and asks for the 6-digit code.",
            "From then on just click \"Open Desktop\" — Bifrost auto-reconnects ADB and opens the window.",
        ],
        permissions: [.phoneWirelessDebug],
        troubleshooting: "\"No phone over ADB\"? Android switches Wireless debugging off now and then — flip it back on and retry. Homebrew missing? Install it from brew.sh, then run \"brew install scrcpy\". Still stuck? Open the Setup guide — it shows exactly which step is failing, live."
    )

    static let clipboard = FeatureHelp(
        title: "Clipboard",
        icon: "doc.on.clipboard",
        what: "Keeps both clipboards in step over the encrypted link. With Auto-sync on, anything you copy on this Mac lands on the phone's clipboard instantly. Text copied on the phone arrives on the Mac clipboard and shows under LAST RECEIVED.",
        steps: [
            "Leave \"Auto-sync to phone\" on — every Mac copy is pushed automatically.",
            "\"Send now\" pushes the current Mac clipboard once (useful with Auto-sync off).",
            "\"Open link on phone\": if the clipboard holds an http/https URL, the phone opens it in its browser — instant tab handoff.",
            "Copied something on the phone? It's already on this Mac's clipboard — just paste.",
        ],
        permissions: [],
        troubleshooting: "\"Clipboard doesn't contain a link\" in the Activity log means the copied text isn't an http/https URL. Nothing syncing at all? Confirm the phone is connected (green dot up top) and check the Activity log."
    )

    static let files = FeatureHelp(
        title: "Files",
        icon: "arrow.up.doc",
        what: "Sends files to the phone over the encrypted link — no cloud, no size limits beyond your disk. Files the phone sends back land in your Downloads folder and are revealed in Finder automatically.",
        steps: [
            "Click \"Send file…\" and pick one or more files.",
            "Or drag files anywhere onto this window — the whole window is a drop zone.",
            "Photos & videos can be dragged straight out of the Photos app: Bifrost copies them to a safe temp location first, so the transfer works even though Photos deletes its drag file immediately.",
            "Watch transfer progress right on the card; received files are revealed in Downloads when done.",
        ],
        permissions: [],
        troubleshooting: "Drops are ignored unless the phone is paired and connected. If a transfer stalls, check the Activity log — every transfer logs its progress and errors there."
    )

    static let audio = FeatureHelp(
        title: "Audio",
        icon: "speaker.wave.2",
        what: "Two directions. ① Stream this Mac's system audio to the phone — whatever the Mac plays comes out of the phone's speaker or whatever Bluetooth device the phone is connected to (48 kHz stereo). ② Use the phone as a wireless microphone for this Mac, with a live level meter.",
        steps: [
            "Mac → phone: flip \"Stream Mac audio to phone\". Audio follows the phone's current output — pair the phone to any Bluetooth speaker or earbuds to use them from the Mac.",
            "Phone as mic: start it FROM THE PHONE (\"Use as Mac microphone\"). A red LIVE row with a level meter appears on this card.",
            "Meter moving = audio arriving. The dropdown picks where the mic audio plays; the choice applies the next time the mic starts.",
            "Use the phone mic in Zoom/Meet/etc: install the free BlackHole virtual audio driver, pick BlackHole in the dropdown here, then select BlackHole as the microphone inside the app. Bifrost plays the phone's audio into BlackHole; the app hears it as a mic.",
        ],
        permissions: [.screenRecording],
        troubleshooting: "No sound on the phone? Check the phone's volume and audio route. The audio toggle flips itself back off? That's the missing Screen Recording permission — grant it, then quit & reopen Bifrost. Meter frozen? Stop and restart the mic from the phone; details land in the Activity log."
    )

    static let remote = FeatureHelp(
        title: "Remote",
        icon: "rectangle.on.rectangle",
        what: "See and fetch what's on either device. View the phone's screen live in a window here, mirror this Mac's screen to the phone, browse the phone's files and photo gallery from the Mac, pull photos, or ping the phone to find it.",
        steps: [
            "View phone screen: click it, then ACCEPT the share request that pops up on the phone.",
            "Mirror Mac to phone: streams this screen to the phone (needs Screen Recording below).",
            "Browse phone files: navigate folders, click files to select, then Download — they land in Downloads. You can also drop Mac files onto the browser to send them into the open folder.",
            "Browse phone gallery: thumbnails stream in as you scroll. Click to select, then Download pulls the full-resolution originals into Downloads.",
            "Ping phone: the phone beeps/buzzes so you can find it — and it confirms the link is alive.",
        ],
        permissions: [.screenRecording, .phoneAllFiles],
        troubleshooting: "Phone screen stays black? The phone is showing a consent dialog — accept it there. File browser asks for permission? Grant \"All files access\" on the phone (it opens the right Settings screen), then click Browse again."
    )

    static let syncFolder = FeatureHelp(
        title: "Sync Folder",
        icon: "arrow.triangle.2.circlepath",
        what: "A private two-way mirror — a personal Dropbox with no cloud. This Mac folder (default ~/Bifrost Sync, changeable) mirrors the phone's Internal storage/Bifrost Sync folder. Every 10 seconds both sides exchange a file list (path, size, modified time); whichever side is missing a file or has an older copy pulls it over the encrypted link. Newest edit wins — and sync NEVER deletes anything.",
        steps: [
            "Flip the toggle to start. \"Choose…\" picks a different Mac folder; \"Open\" reveals it in Finder.",
            "Drop files in on either device — they appear on the other side within ~10 seconds.",
            "Same file edited on both sides? The newer save wins, but the losing copy is NOT lost: it's moved to a hidden .bifrost-trash folder inside the sync folder, timestamped, so you can always recover it.",
            "Deleting a file does NOT delete it on the other device — sync only adds and updates. Clean up on both sides by hand.",
            "Keep it under 1,000 files: beyond that, extra files are skipped (the Activity log warns you). Hidden files and in-flight .part files are never synced.",
        ],
        permissions: [],
        troubleshooting: "Status stuck on \"Syncing…\"? Check the connection and the Activity log. A tiny edit didn't sync? Timestamps must differ by more than 2 s — Android storage rounds file times, so Bifrost deliberately ignores smaller differences. Need an overwritten version back? It's in .bifrost-trash inside the sync folder (press Cmd+Shift+. in Finder to show hidden files)."
    )

    static let nowPlaying = FeatureHelp(
        title: "Now Playing",
        icon: "music.note",
        what: "Whatever is playing on the phone — Spotify, YouTube, podcasts — shows here with artwork, and the buttons control the phone: previous, play/pause, next. The card appears only while the phone reports active media.",
        steps: [
            "Play something on the phone — the card appears here by itself.",
            "Use ⏮ ⏯ ⏭ to control the phone's playback from the Mac.",
            "The reverse also works: the phone can act as a remote for THIS Mac's playback and presentations — that direction needs the Accessibility permission (a ⚠ chip appears above the cards if it's missing).",
        ],
        permissions: [],
        troubleshooting: "Card missing? Nothing is playing on the phone, or the phone-side Bifrost app hasn't been granted media/notification access on Android. Buttons doing nothing? Check the Activity log and the phone's media app."
    )

    static let phoneBattery = FeatureHelp(
        title: "Phone Battery",
        icon: "battery.75",
        what: "Your phone's battery, always in sight on this Mac: a battery glyph with the percentage in the menu bar (bolt while charging) and a badge in the connected header. Bifrost alerts you once when the battery drops to 20% without a charger, and nudges you once when it sits at 100% still plugged in — each alert fires once per episode, not repeatedly.",
        steps: [
            "Nothing to configure — the level arrives with the phone's regular heartbeat and updates instantly when you plug or unplug the charger.",
            "Glance at the menu bar: the battery glyph and percentage sit next to the Bifrost icon; hover for a tooltip.",
            "At ≤20% and not charging you get one \"Phone battery low\" banner; at 100% still plugged in, one \"fully charged\" nudge.",
            "The badge in the header turns orange when the battery is low.",
        ],
        permissions: [.notifications],
        troubleshooting: "No battery showing? The phone hasn't sent a reading yet — it arrives within seconds of connecting; make sure the phone app is up to date. No low/full alerts? Allow notifications for Bifrost (see above)."
    )

    static let notificationActions = FeatureHelp(
        title: "Notification Actions",
        icon: "bell.badge",
        what: "Mirrored phone notifications on this Mac carry the notification's own buttons — up to three actions (Archive, Mark as read, Like, …) plus \"Dismiss on phone\" — alongside the existing inline Reply. Clicking a button fires the real action on the phone, exactly as if you'd tapped it there.",
        steps: [
            "A phone notification pops up as a Mac banner. Hover it and click Options (or long-click the banner) to see its buttons.",
            "Click an action — the phone fires it and the notification updates or clears there.",
            "\"Dismiss on phone\" swipes the notification away on the phone without opening it.",
            "Repliable notifications keep the inline Reply field — type and press Send as before.",
        ],
        permissions: [.notifications, .phoneNotificationAccess],
        troubleshooting: "No buttons on a banner? That notification has no actions, or it came from an older phone app. Clicked but nothing happened? The notification may already be gone on the phone — check the Activity log."
    )

    static let callBanner = FeatureHelp(
        title: "Call Banner",
        icon: "phone.arrow.down.left",
        what: "When your phone rings, this Mac shows a high-priority banner with the caller's name and number and two buttons: Silence (mutes the ringer for this ring only — your previous ringer mode comes back after the call) and Decline (rejects the call). Bifrost also pauses the Mac's local media playback so you actually hear the phone — it does not auto-resume. Once you're ON a call, an \"On call\" row appears in the connected header with live controls: Hang up, Mute/Unmute and Speaker.",
        steps: [
            "Phone rings → banner appears here with the caller and the ringing indicator shows in the header.",
            "Silence: the phone stops ringing but the call keeps ringing for the caller — answer on the phone if you want it.",
            "Decline: the call is rejected outright.",
            "Once the call connects, the \"On call — <caller>\" row in the header lets you Hang up (ends the call), Mute/Unmute the mic, and toggle Speaker — all from the Mac. Hang up is also in the menu bar.",
            "Mute and Speaker mirror the phone's REAL state: the button highlights only after the phone confirms the change, so it never shows the wrong state. Answer or end the call on the phone (or click Hang up) and the row clears by itself.",
        ],
        permissions: [.notifications, .phoneCallAccess],
        troubleshooting: "No banner when the phone rings? Grant the phone-side permissions (the phone app shows grant buttons for each) and allow notifications for Bifrost here. Media didn't pause? The play/pause key needs the Accessibility-style event injection to be permitted — check the Activity log. Mute or Speaker didn't flip? Those are best-effort on the phone — some Android versions or Bluetooth headsets won't let an app change them, so Bifrost leaves the toggle where it is rather than lying. Hang up needs the phone's \"Answer calls\" permission."
    )

    static let activity = FeatureHelp(
        title: "Activity",
        icon: "list.bullet.rectangle",
        what: "A live, timestamped log of everything the link does: pairing, clipboard and file transfers, sync passes, audio/screen sessions — and precise error messages whenever something can't run. It keeps the last 200 entries.",
        steps: [
            "Nothing to configure — it just runs.",
            "When a feature doesn't respond, look here FIRST: most failures log exactly what's wrong and what to do (e.g. \"no phone over ADB\", \"Clipboard doesn't contain a link\").",
            "Newest entries are at the bottom; the log auto-scrolls.",
        ],
        permissions: [],
        troubleshooting: "The log IS the troubleshooter. If it's empty and the phone won't connect, check that both devices are on the same network — or fall back to the USB link (see the ? next to the connection header)."
    )
}
