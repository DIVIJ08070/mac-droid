import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @StateObject private var updater = Updater()
    @ObservedObject private var perms = PermissionMonitor.shared
    @State private var isDropTargeted = false
    @State private var showDesktopGuide = false
    @State private var showSplash = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var macName: String {
        Host.current().localizedName ?? "Mac"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            mainScreen

            if !hasCompletedOnboarding {
                OnboardingView {
                    withAnimation(.easeOut(duration: 0.4)) {
                        hasCompletedOnboarding = true
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }

            if showSplash {
                SplashView { showSplash = false }
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .frame(minWidth: 640, minHeight: 640)
        .preferredColorScheme(.dark)
        .onAppear {
            updater.check()
            PermissionMonitor.shared.start()
        }
        .overlay { dropOverlay }
        .onDrop(of: [.fileURL, .image, .movie], isTargeted: $isDropTargeted) { providers in
            guard server.isPaired else { return false }
            var handledAny = false
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    handledAny = true
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in server.sendFile(url: url) }
                    }
                } else if let type = [UTType.image, UTType.movie]
                    .first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                    // Photos.app and similar apps drag media data, not file URLs. The
                    // provider's temp file is deleted when the handler returns, so copy
                    // it out before handing it to the (async) transfer.
                    handledAny = true
                    let suggestedName = provider.suggestedName
                    _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                        guard let url else { return }
                        let dropDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent("MacDroidDrops", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
                        var name = url.lastPathComponent
                        if let suggestedName, !suggestedName.isEmpty {
                            name = suggestedName
                            let ext = url.pathExtension
                            if !ext.isEmpty && (name as NSString).pathExtension.isEmpty {
                                name += ".\(ext)"
                            }
                        }
                        let destination = dropDir.appendingPathComponent(name)
                        try? FileManager.default.removeItem(at: destination)
                        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return }
                        Task { @MainActor in server.sendFile(url: destination) }
                    }
                }
            }
            return handledAny
        }
    }

    // MARK: - Main screen

    private var updateAccent: Color { Color(red: 0.49, green: 0.42, blue: 1.0) }

    private var updateBannerFailed: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var updateBannerTitle: String {
        switch updater.phase {
        case .failed:                    return "Update failed"
        case .downloading, .installing:  return "Updating to Bifrost \(updater.latestVersion ?? "")"
        default:                         return "Update available — Bifrost \(updater.latestVersion ?? "")"
        }
    }

    private var updateBannerSubtitle: String {
        switch updater.phase {
        case .idle:                 return "You have \(updater.currentVersion). One click to update in place."
        case .downloading(let p):   return "Downloading… \(Int(p * 100))%"
        case .installing:           return "Installing and restarting…"
        case .failed(let message):  return message
        }
    }

    @ViewBuilder private var updateBannerControl: some View {
        switch updater.phase {
        case .idle:
            Button("Update") { updater.installUpdate() }
                .buttonStyle(PillButtonStyle(kind: .primary, size: 11))
        case .downloading(let p):
            ProgressView(value: p)
                .progressViewStyle(.linear)
                .tint(updateAccent)
                .frame(width: 96)
        case .installing:
            ProgressView().controlSize(.small)
        case .failed:
            HStack(spacing: 8) {
                Button("Retry") { updater.installUpdate() }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: 11))
                Button("Browser") { updater.openInBrowser() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: 11))
            }
        }
    }

    private var updateBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: updateBannerFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(updateBannerFailed ? Color.orange : updateAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(updateBannerTitle)
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(.white)
                Text(updateBannerSubtitle)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            updateBannerControl
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(updateAccent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(updateAccent.opacity(0.4), lineWidth: 1)
        )
    }

    private var mainScreen: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if updater.updateAvailable {
                        updateBanner
                            .riseIn(delay: 0.0)
                    }

                    statusHeader
                        .riseIn(delay: 0.05)

                    if !perms.accessibilityOK || !perms.notificationsOK || !perms.screenRecordingOK {
                        permissionsStrip
                            .riseIn(delay: 0.07)
                    }

                    if let code = server.pendingPairCode {
                        pairingCard(code: code)
                            .riseIn(delay: 0.1)
                    }

                    if server.isPaired {
                        featureGrid
                            .riseIn(delay: 0.15)
                    }

                    if let phoneTab = server.phoneTabURL {
                        phoneTabRow(url: phoneTab)
                            .riseIn(delay: 0.2)
                    }

                    activityCard
                        .riseIn(delay: server.isPaired ? 0.25 : 0.15)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text("BIFROST")
                .font(Theme.mono(11, .medium))
                .tracking(4)
                .foregroundStyle(Theme.faint)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.4)) {
                    hasCompletedOnboarding = false
                }
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Show intro")
        }
    }

    // MARK: - Status header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if server.isPaired {
                HStack(spacing: 8) {
                    SectionLabel("Connected")
                    HelpButton(help: .connection)
                }
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(red: 0.45, green: 0.95, blue: 0.6))
                        .frame(width: 8, height: 8)
                    Text(server.connectedDeviceName ?? "Phone")
                        .font(Theme.mono(24, .light))
                        .foregroundStyle(.white)
                    if let level = server.phoneBattery {
                        batteryBadge(level: level, charging: server.phoneCharging)
                    }
                }
                if server.callState == "ringing" {
                    HStack(spacing: 8) {
                        PulsingDot(color: .orange)
                        Text("Incoming call\(server.callerDisplay.isEmpty ? "" : " — \(server.callerDisplay)")")
                            .font(Theme.mono(12))
                            .foregroundStyle(.orange)
                        HelpButton(help: .callBanner)
                    }
                }
                if server.callState == "offhook" {
                    onCallRow
                }
                Text("Clipboard, files, audio and input — live over your private link.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
                    .lineSpacing(4)
                HStack(spacing: 16) {
                    featureHint(icon: "bell.badge", label: "notification buttons", help: .notificationActions)
                    featureHint(icon: "phone.arrow.down.left", label: "call banner", help: .callBanner)
                }
            } else if server.pendingPairCode != nil {
                SectionLabel("Pairing")
                HStack(spacing: 10) {
                    PulsingDot(color: .white)
                    Text(server.connectedDeviceName ?? "Phone")
                        .font(Theme.mono(24, .light))
                        .foregroundStyle(.white)
                }
                Text("A pairing request is waiting below.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
            } else {
                HStack(spacing: 8) {
                    SectionLabel("Waiting")
                    HelpButton(help: .connection)
                }
                HStack(spacing: 10) {
                    PulsingDot(color: .white)
                    Text("Advertising as \(macName)")
                        .font(Theme.mono(24, .light))
                        .foregroundStyle(.white)
                }
                Text("Open Bifrost on your phone — connect any way you like: same Wi-Fi, the phone's hotspot, a USB cable, or Tailscale from anywhere.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Using a USB cable? Set up the USB link") { server.enableUSBLink() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: 11))
                Text("Away from home? Connect by address on the phone using your Tailscale IP · port \(String(ServerManager.fixedPort)). USB uses 127.0.0.1:\(String(ServerManager.fixedPort)).")
                    .font(Theme.mono(10))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .fixedSize(horizontal: false, vertical: true)
                Text(server.statusText)
                    .font(Theme.mono(10))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ongoing (offhook) call controls

    /// Compact live-call row in the connected header: caller + Hang up / Mute /
    /// Speaker. Mute & Speaker reflect the phone's REAL reported state (callMuted
    /// / callSpeaker) — we send the action and let the next call.state flip them,
    /// so a toggle never lies if the phone's OS refused the change.
    private var onCallRow: some View {
        let callAccent = Color(red: 0.45, green: 0.95, blue: 0.6)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "phone.connection.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(callAccent)
                Text("On call\(server.callerDisplay.isEmpty ? "" : " — \(server.callerDisplay)")")
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HelpButton(help: .callBanner)
            }
            HStack(spacing: 8) {
                Button {
                    server.callAction("hangup")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "phone.down.fill")
                        Text("Hang up")
                    }
                }
                .buttonStyle(CallControlStyle(active: false, destructive: true))

                Button {
                    server.callAction(server.callMuted ? "unmute" : "mute")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: server.callMuted ? "mic.slash.fill" : "mic.fill")
                        Text(server.callMuted ? "Unmute" : "Mute")
                    }
                }
                .buttonStyle(CallControlStyle(active: server.callMuted, destructive: false))

                Button {
                    server.callAction(server.callSpeaker ? "speaker_off" : "speaker_on")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: server.callSpeaker ? "speaker.wave.2.fill" : "speaker.fill")
                        Text("Speaker")
                    }
                }
                .buttonStyle(CallControlStyle(active: server.callSpeaker, destructive: false))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(callAccent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(callAccent.opacity(0.4), lineWidth: 1)
        )
    }

    /// Small capsule with the phone's battery: tiered SF Symbols glyph (bolt when
    /// charging) + percentage, orange when low, with a "?" opening the full guide.
    private func batteryBadge(level: Int, charging: Bool) -> some View {
        let low = level <= 20 && !charging
        return HStack(spacing: 6) {
            Image(systemName: ServerManager.batterySymbol(level: level, charging: charging))
                .font(.system(size: 12))
                .foregroundStyle(low ? Color.orange : Theme.dim)
            Text("\(level)%")
                .font(Theme.mono(11))
                .foregroundStyle(low ? Color.orange : .white.opacity(0.85))
            HelpButton(help: .phoneBattery)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
        .help("Phone battery: \(level)%\(charging ? " · charging" : "")")
    }

    /// One-line pointer to an always-on background feature and its "?" guide.
    private func featureHint(icon: String, label: String, help: FeatureHelp) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
            Text(label)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
            HelpButton(help: help)
        }
    }

    // MARK: - Pairing

    private func pairingCard(code: String) -> some View {
        VStack(spacing: 16) {
            SectionLabel("Pairing request")
            Text(code)
                .font(Theme.mono(48, .light))
                .tracking(10)
                .foregroundStyle(.white)
            Text("Confirm this code matches your phone.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.dim)
            HStack(spacing: 12) {
                Button("Decline") { server.rejectPairing() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: 13))
                Button("Accept") { server.acceptPairing() }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: 13))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .card(fillOpacity: 0.1)
    }

    // MARK: - Feature cards

    private var featureGrid: some View {
        VStack(spacing: 12) {
            desktopModeCard
            if server.nowPlaying != nil {
                nowPlayingCard
            }
            HStack(alignment: .top, spacing: 12) {
                clipboardCard
                filesCard
            }
            HStack(alignment: .top, spacing: 12) {
                audioCard
                remoteCard
            }
            syncCard
        }
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                cardHeader("Sync Folder", icon: "arrow.triangle.2.circlepath", help: .syncFolder)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { server.syncFolder.enabled },
                    set: { on in
                        server.syncFolder.enabled = on
                        if on { server.syncFolder.start() } else { server.syncFolder.stop() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.white.opacity(0.4))
            }
            Text("Mirrors a folder here with the “Bifrost Sync” folder on your phone — both ways, newest wins. Nothing is deleted by sync.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.faint)
                .lineSpacing(3)
            HStack(spacing: 8) {
                Text(server.syncFolder.folderPath)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseSyncFolder() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: 10))
                Button("Open") {
                    server.syncFolder.ensureFolder()
                    NSWorkspace.shared.open(server.syncFolder.folderURL)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, size: 10))
            }
            if server.syncFolder.enabled, !server.syncFolder.status.isEmpty {
                Text("✓ \(server.syncFolder.status)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            }
        }
        .card()
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            server.syncFolder.folderPath = url.path
            if server.syncFolder.enabled { server.syncFolder.start() }
        }
    }

    @ViewBuilder
    private var nowPlayingCard: some View {
        if let np = server.nowPlaying {
            HStack(spacing: 14) {
                Group {
                    if let art = np.art {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.06))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        SectionLabel("Now Playing")
                        HelpButton(help: .nowPlaying)
                    }
                    Text(np.title.isEmpty ? "Unknown" : np.title)
                        .font(Theme.mono(14, .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(np.artist)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 6) {
                    mediaButton("backward.fill") { server.mediaCommand("prev") }
                    mediaButton(np.playing ? "pause.fill" : "play.fill") { server.mediaCommand("playpause") }
                    mediaButton("forward.fill") { server.mediaCommand("next") }
                }
            }
            .card()
        }
    }

    private func mediaButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    // A standalone, highlighted card — Desktop Mode is the marquee feature.
    private var desktopModeCard: some View {
        let accent = Color(red: 0.49, green: 0.42, blue: 1.0) // fixed indigo/violet
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(accent)
                Text("DESKTOP MODE")
                    .font(Theme.mono(11, .semibold))
                    .tracking(3)
                    .foregroundStyle(.white)
                Text("BETA")
                    .font(Theme.mono(8, .bold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(accent))
                HelpButton(help: .desktopMode)
                Spacer()
            }

            Text("Open a full Android desktop in its own window on your Mac. Apps run on a separate screen — your phone stays free to use.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.dim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                Text("First time? The Setup guide walks you through everything and checks each step live.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    server.launchDesktopMode()
                } label: {
                    HStack(spacing: 8) {
                        if server.desktopStarting {
                            ProgressView().controlSize(.small).tint(.black)
                            Text("Connecting…")
                        } else {
                            Image(systemName: "arrow.up.forward.app")
                            Text("Open Desktop")
                        }
                    }
                }
                .buttonStyle(SolidButtonStyle(fill: accent))
                .disabled(server.desktopStarting)

                Button("Setup guide") { showDesktopGuide = true }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: 12))
            }
            .sheet(isPresented: $showDesktopGuide) {
                DesktopSetupView(server: server)
            }

            // Optional / advanced, listed last: keyboard+mouse for games.
            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 4) {
                Text("⌨️ Play games with keyboard & mouse — advanced")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.dim)
                Text("Use the free tool ").font(Theme.mono(10)).foregroundColor(Theme.faint)
                + Text("QtScrcpy").font(Theme.mono(10, .medium)).foregroundColor(Color(red: 0.49, green: 0.42, blue: 1.0))
                + Text(" for a low-latency key-mapper.").font(Theme.mono(10)).foregroundColor(Theme.faint)
                Text("⚠️ At your own risk — mapping keys/mouse may break a game's rules and get your account banned. Check the game's Terms first.")
                    .font(Theme.mono(9))
                    .foregroundStyle(Color(red: 0.95, green: 0.7, blue: 0.3).opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open QtScrcpy ↗") {
                    if let url = URL(string: "https://github.com/barry-ran/QtScrcpy/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.mono(10, .medium))
                .foregroundStyle(Color(red: 0.49, green: 0.42, blue: 1.0))
                .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(accent.opacity(0.55), lineWidth: 1.2)
        )
    }

    private var clipboardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Clipboard", icon: "doc.on.clipboard", help: .clipboard)
            Toggle(isOn: $server.autoSyncClipboard) {
                Text("Auto-sync to phone")
                    .font(Theme.mono(12))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color.white.opacity(0.4))
            wrapButtons {
                Button("Send now") { server.sendClipboardNow() }
                Button("Open link on phone") { server.sendClipboardURL() }
            }
            if let clip = server.lastReceivedClipboard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAST RECEIVED")
                        .font(Theme.mono(9))
                        .tracking(2)
                        .foregroundStyle(Theme.faint)
                    Text(clip)
                        .lineLimit(3)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }
        }
        .card()
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Files", icon: "arrow.up.doc", help: .files)
            wrapButtons {
                Button("Send file…") { pickAndSendFiles() }
            }
            Text("Or drag files — or photos straight from Photos — anywhere onto this window.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.faint)
                .lineSpacing(3)
            if let transfer = server.transferStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(transfer)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .card()
    }

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                cardHeader("Audio", icon: "speaker.wave.2", help: .audio)
                if !perms.screenRecordingOK {
                    PermissionWarningBadge(info: .screenRecording)
                }
            }
            Toggle(isOn: Binding(
                get: { server.speakerStreaming },
                set: { enabled in
                    if enabled { server.startSpeakerStream() } else { server.stopSpeakerStream() }
                }
            )) {
                Text("Stream Mac audio to phone")
                    .font(Theme.mono(12))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color.white.opacity(0.4))
            Text("Plays on the phone's Bluetooth or speaker.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.faint)
                .lineSpacing(3)
            MicStatusView(mic: server.micReceiver)
        }
        .card()
    }

    private var remoteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                cardHeader("Remote", icon: "rectangle.on.rectangle", help: .remote)
                if !perms.screenRecordingOK {
                    PermissionWarningBadge(info: .screenRecording)
                }
            }
            wrapButtons {
                if server.screenViewing {
                    Button("Stop viewing screen") { server.stopPhoneScreen() }
                } else {
                    Button("View phone screen") { server.requestPhoneScreen() }
                }
                if server.mirroringToPhone {
                    Button("Stop mirroring") { server.stopMirrorToPhone() }
                } else {
                    Button("Mirror Mac to phone") { server.startMirrorToPhone() }
                }
                Button("Browse phone files") { server.browsePhoneFiles() }
                Button("Browse phone gallery") { server.browsePhoneGallery() }
                Button("Pull photos from phone…") { server.pullPhotosFromPhone() }
                Button("Ping phone") { server.pingPhone() }
            }
            if server.fileBrowsing {
                fileBrowser
            }
            if server.galleryLoading || !server.galleryThumbs.isEmpty {
                galleryGrid
            }
        }
        .card()
    }

    @State private var fsDropTargeted = false
    @State private var selectedFiles: Set<String> = []

    private var fileBrowser: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if !server.fsParent.isEmpty { server.fsNavigate(to: server.fsParent) }
                } label: { Image(systemName: "chevron.up") }
                .disabled(server.fsParent.isEmpty)
                Text(server.fsPath.isEmpty ? "Phone storage" : server.fsPath)
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if !selectedFiles.isEmpty {
                    Button("Download \(selectedFiles.count)") {
                        for name in selectedFiles { server.fsDownload(name: name) }
                        selectedFiles.removeAll()
                    }
                    .font(.caption)
                }
                Button("Close") { server.closeFileBrowser(); selectedFiles.removeAll() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.faint)
            }
            if server.fsNeedsPermission {
                Text("Grant \"All files access\" on the phone (it just opened Settings), then click Browse again.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(server.fsEntries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.isDir ? "folder.fill" : (selectedFiles.contains(entry.name) ? "checkmark.circle.fill" : "doc"))
                                .foregroundStyle(entry.isDir ? Color.accentColor : (selectedFiles.contains(entry.name) ? Color.accentColor : Theme.faint))
                                .frame(width: 16)
                            Text(entry.name).lineLimit(1)
                            Spacer()
                            if !entry.isDir {
                                Text(Self.humanSize(entry.size))
                                    .font(.caption).foregroundStyle(Theme.faint)
                            }
                        }
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        .background(selectedFiles.contains(entry.name) ? Color.accentColor.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if entry.isDir {
                                server.fsNavigate(to: server.fsPath + "/" + entry.name)
                                selectedFiles.removeAll()
                            } else if selectedFiles.contains(entry.name) {
                                selectedFiles.remove(entry.name)
                            } else {
                                selectedFiles.insert(entry.name)
                            }
                        }
                        .help(entry.isDir ? "Open folder" : "Click to select · then Download")
                    }
                }
            }
            .frame(height: 240)
            .background(fsDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(alignment: .bottom) {
                Text("Drop Mac files here to send to this folder")
                    .font(.caption2).foregroundStyle(Theme.faint).padding(4)
            }
            .onDrop(of: [.fileURL], isTargeted: $fsDropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in server.fsPush(urls: [url]) }
                    }
                }
                return true
            }
        }
    }

    private static func humanSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @State private var selectedPhotos: Set<Int> = []

    private var galleryGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(server.galleryThumbs.isEmpty && server.galleryLoading
                     ? "Loading gallery…"
                     : selectedPhotos.isEmpty
                        ? "\(server.galleryThumbs.count) photos · click to select"
                        : "\(selectedPhotos.count) selected")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
                Spacer()
                if !selectedPhotos.isEmpty {
                    Button("Download \(selectedPhotos.count)") {
                        server.pullGalleryImages(ids: Array(selectedPhotos))
                        selectedPhotos.removeAll()
                    }
                    .font(.caption)
                }
                if !server.galleryThumbs.isEmpty {
                    Button("Close") {
                        server.galleryThumbs = []; server.galleryHasMore = false; selectedPhotos.removeAll()
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.faint)
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(server.galleryThumbs) { thumb in
                        Image(nsImage: thumb.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                if selectedPhotos.contains(thumb.id) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.accentColor, lineWidth: 3)
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.white, Color.accentColor)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                        .padding(4)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedPhotos.contains(thumb.id) { selectedPhotos.remove(thumb.id) }
                                else { selectedPhotos.insert(thumb.id) }
                            }
                            .help("Click to select · then Download")
                            .onAppear {
                                // Infinite scroll: load the next page as the last row appears.
                                if thumb.id == server.galleryThumbs.last?.id { server.loadMoreGallery() }
                            }
                    }
                }
                .padding(.vertical, 2)
                if server.galleryLoading && !server.galleryThumbs.isEmpty {
                    ProgressView().controlSize(.small).padding(.vertical, 6)
                }
            }
            .frame(height: 220)
        }
    }

    private func cardHeader(_ title: String, icon: String, help: FeatureHelp? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.faint)
            SectionLabel(title)
            if let help {
                HelpButton(help: help)
            }
        }
    }

    // MARK: - Permission badges

    /// Legend + chips for missing permissions. The legend renders whenever ANY
    /// warning can appear (including the per-card Screen Recording badges), so
    /// the ⚠ symbol is explained the first time the user meets it. Chips cover
    /// permissions whose features are phone-driven (no Mac card): touchpad/
    /// presenter/media keys (Accessibility) and banners (Notifications).
    private var permissionsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.85))
                Text("means a macOS permission is missing — that feature won't work until you grant it. Hover or click any badge for details.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !perms.accessibilityOK || !perms.notificationsOK {
                HStack(spacing: 8) {
                    if !perms.accessibilityOK {
                        PermissionWarningChip(info: .accessibility)
                    }
                    if !perms.notificationsOK {
                        PermissionWarningChip(info: .notifications)
                    }
                    Spacer()
                }
            }
        }
    }

    /// Lays out small secondary pill buttons, wrapping onto rows.
    @ViewBuilder
    private func wrapButtons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, size: 11))
    }

    // MARK: - Phone tab handoff

    private func phoneTabRow(url phoneTab: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Theme.dim)
            VStack(alignment: .leading, spacing: 3) {
                Text("OPEN ON YOUR PHONE")
                    .font(Theme.mono(9))
                    .tracking(2)
                    .foregroundStyle(Theme.faint)
                Text(server.phoneTabTitle.isEmpty ? phoneTab : server.phoneTabTitle)
                    .font(Theme.mono(12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
            Button("Open here") {
                if let url = URL(string: phoneTab) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, size: 11))
        }
        .card()
    }

    // MARK: - Activity log

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("Activity")
                HelpButton(help: .activity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if server.log.isEmpty {
                            Text("Nothing yet. Waiting for your phone.")
                                .font(Theme.mono(11))
                                .foregroundStyle(Color.white.opacity(0.3))
                        }
                        ForEach(Array(server.log.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.dim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: server.log.count) { _ in
                    proxy.scrollTo(server.log.count - 1, anchor: .bottom)
                }
            }
            .frame(minHeight: 110, maxHeight: 160)
        }
        .card(fillOpacity: 0.04)
    }

    // MARK: - Drop overlay

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted && server.isPaired {
            ZStack {
                Color.black.opacity(0.75)
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                    )
                    .padding(14)
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white)
                    Text("Drop to send to phone")
                        .font(Theme.mono(15, .light))
                        .foregroundStyle(.white)
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Mic status (kept from original, restyled)

    private struct MicStatusView: View {
        @ObservedObject var mic: MicReceiver

        var body: some View {
            if mic.isActive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        Text("Phone mic LIVE — playing to:")
                            .font(Theme.mono(11))
                            .foregroundStyle(.white)
                    }
                    levelMeter
                    Picker("", selection: $mic.selectedDeviceID) {
                        Text("System default").tag(AudioDeviceID(0))
                        ForEach(mic.outputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Text("Applies when the mic is next started. To use in apps (Zoom etc.), install BlackHole, pick it here, then select BlackHole as input in the app.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                        .lineSpacing(3)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                        Text("PHONE AS MIC")
                            .font(Theme.mono(9))
                            .tracking(2)
                            .foregroundStyle(Theme.faint)
                    }
                    Text("Start it from the phone: “Use as Mac microphone”. A live meter appears here. If nothing happens, check the Activity log below.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                        .lineSpacing(3)
                }
            }
        }

        private var levelMeter: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(Color(red: 0.45, green: 0.95, blue: 0.6))
                        .frame(width: max(4, geo.size.width * CGFloat(mic.level)))
                        .animation(.linear(duration: 0.08), value: mic.level)
                }
            }
            .frame(width: 220, height: 5)
        }
    }

    // MARK: - Actions

    private func pickAndSendFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to send to your phone"
        if panel.runModal() == .OK {
            for url in panel.urls {
                server.sendFile(url: url)
            }
        }
    }
}
