import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var server: ServerManager
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let code = server.pendingPairCode {
                pairingCard(code: code)
            }

            if server.isPaired {
                actionsCard
            }

            logView
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 520)
        .overlay {
            if isDropTargeted && server.isPaired {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.1))
                    .overlay(Text("Drop to send to phone").font(.title2).bold())
                    .padding(8)
            }
        }
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

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(server.isPaired ? Color.green : (server.connectedDeviceName != nil ? Color.orange : Color.secondary))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading) {
                Text(server.statusText).font(.headline)
                if let name = server.connectedDeviceName {
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func pairingCard(code: String) -> some View {
        GroupBox("Pairing request") {
            VStack(spacing: 12) {
                Text("Confirm this code matches your phone:")
                Text(code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                HStack {
                    Button("Reject") { server.rejectPairing() }
                    Button("Accept") { server.acceptPairing() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(8)
        }
    }

    private var actionsCard: some View {
        GroupBox("Connected") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Auto-sync clipboard to phone", isOn: $server.autoSyncClipboard)
                HStack {
                    Button("Send clipboard now") { server.sendClipboardNow() }
                    Button("Ping phone") { server.pingPhone() }
                    Button("Send file…") { pickAndSendFiles() }
                    Button("Open link on phone") { server.sendClipboardURL() }
                }
                Toggle("Stream Mac audio to phone (plays on the phone's Bluetooth/speaker)", isOn: Binding(
                    get: { server.speakerStreaming },
                    set: { enabled in
                        if enabled { server.startSpeakerStream() } else { server.stopSpeakerStream() }
                    }
                ))
                MicStatusView(mic: server.micReceiver)
                if let phoneTab = server.phoneTabURL {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open on your phone:").font(.caption).foregroundStyle(.secondary)
                            Text(server.phoneTabTitle.isEmpty ? phoneTab : server.phoneTabTitle)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Open here") {
                            if let url = URL(string: phoneTab) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Text("Tip: you can also drag files onto this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let transfer = server.transferStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(transfer).font(.callout)
                    }
                }
                if let clip = server.lastReceivedClipboard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last received from phone:").font(.caption).foregroundStyle(.secondary)
                        Text(clip)
                            .lineLimit(3)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private struct MicStatusView: View {
        @ObservedObject var mic: MicReceiver

        var body: some View {
            if mic.isActive {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").foregroundStyle(.red)
                        Text("Phone microphone is live — playing to:")
                        Picker("", selection: $mic.selectedDeviceID) {
                            Text("System default").tag(AudioDeviceID(0))
                            ForEach(mic.outputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                    Text("Device choice applies when the mic is next started. To use it as a microphone in apps (Zoom etc.), install BlackHole, pick it here, then select BlackHole as input in the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

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

    private var logView: some View {
        GroupBox("Activity") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(server.log.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: server.log.count) { _ in
                    proxy.scrollTo(server.log.count - 1, anchor: .bottom)
                }
            }
            .frame(minHeight: 120)
        }
    }
}
