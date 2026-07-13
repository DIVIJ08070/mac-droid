import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @State private var isDropTargeted = false
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
        }
        .frame(minWidth: 640, minHeight: 640)
        .preferredColorScheme(.dark)
        .overlay { dropOverlay }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard server.isPaired else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in server.sendFile(url: url) }
                }
            }
            return true
        }
    }

    // MARK: - Main screen

    private var mainScreen: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusHeader
                        .riseIn(delay: 0.05)

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
            Text("MACDROID")
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
                SectionLabel("Connected")
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(red: 0.45, green: 0.95, blue: 0.6))
                        .frame(width: 8, height: 8)
                    Text(server.connectedDeviceName ?? "Phone")
                        .font(Theme.mono(24, .light))
                        .foregroundStyle(.white)
                }
                Text("Clipboard, files, audio and input — live over your Wi-Fi.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
                    .lineSpacing(4)
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
                SectionLabel("Waiting")
                HStack(spacing: 10) {
                    PulsingDot(color: .white)
                    Text("Advertising as \(macName)")
                        .font(Theme.mono(24, .light))
                        .foregroundStyle(.white)
                }
                Text("Open MacDroid on your phone — same Wi-Fi.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
                Text(server.statusText)
                    .font(Theme.mono(10))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(alignment: .top, spacing: 12) {
                clipboardCard
                filesCard
            }
            HStack(alignment: .top, spacing: 12) {
                audioCard
                remoteCard
            }
        }
    }

    private var clipboardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Clipboard", icon: "doc.on.clipboard")
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
            cardHeader("Files", icon: "arrow.up.doc")
            wrapButtons {
                Button("Send file…") { pickAndSendFiles() }
            }
            Text("Or drag files anywhere onto this window.")
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
            cardHeader("Audio", icon: "speaker.wave.2")
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
            cardHeader("Remote", icon: "rectangle.on.rectangle")
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
                Button("Ping phone") { server.pingPhone() }
            }
        }
        .card()
    }

    private func cardHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.faint)
            SectionLabel(title)
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
            SectionLabel("Activity")
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
                        Text("Phone mic live — playing to:")
                            .font(Theme.mono(11))
                            .foregroundStyle(.white)
                    }
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
            }
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
