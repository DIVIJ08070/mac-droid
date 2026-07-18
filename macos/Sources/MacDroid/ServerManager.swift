import AppKit
import Combine
import Foundation
import Network

/// A one-shot thread-safe flag (readabilityHandler chunks can race).
private final class LockedFlag {
    private let lock = NSLock()
    private var done = false
    /// Returns true exactly once, false on every subsequent call.
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

@MainActor
final class ServerManager: ObservableObject {
    @Published var statusText = "Starting…"
    @Published var port: UInt16?
    @Published var connectedDeviceName: String?
    @Published var pendingPairCode: String?
    @Published var isPaired = false {
        didSet {
            if isPaired && !oldValue { syncFolder.start() }
            else if !isPaired && oldValue { syncFolder.stop() }
        }
    }
    @Published var lastReceivedClipboard: String?
    @Published var autoSyncClipboard = true
    @Published var transferStatus: String?
    @Published var log: [String] = []
    @Published var speakerStreaming = false

    @Published var phoneTabURL: String?
    @Published var phoneTabTitle: String = ""

    @Published var screenViewing = false

    @Published var mirroringToPhone = false

    struct GalleryThumb: Identifiable {
        let id: Int
        let name: String
        let image: NSImage
    }
    @Published var galleryThumbs: [GalleryThumb] = []
    @Published var galleryLoading = false
    @Published var galleryHasMore = false

    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var playing: Bool
        var art: NSImage?
        static func == (l: NowPlaying, r: NowPlaying) -> Bool {
            l.title == r.title && l.artist == r.artist && l.playing == r.playing
        }
    }
    @Published var nowPlaying: NowPlaying?

    // Phone battery, from heartbeats + immediate `battery` packets.
    @Published var phoneBattery: Int?
    @Published var phoneCharging = false
    // One alert per episode: reset when the state that caused it changes.
    private var lowBatteryAlerted = false
    private var fullBatteryAlerted = false

    // Incoming-call state, from `call.state` packets.
    @Published var callState = "idle"
    @Published var callerDisplay = ""
    // Live mic-mute / speakerphone state during an active (offhook) call. These
    // mirror the phone's ACTUAL reported state so the Mac toggles never lie.
    @Published var callMuted = false
    @Published var callSpeaker = false

    struct FileEntry: Identifiable {
        var id: String { name }
        let name: String
        let isDir: Bool
        let size: Int
    }
    @Published var fileBrowsing = false
    @Published var fsPath = ""
    @Published var fsParent = ""
    @Published var fsEntries: [FileEntry] = []
    @Published var fsNeedsPermission = false

    let micReceiver = MicReceiver()
    let syncFolder = SyncFolderManager()
    let universalControl = UniversalControl()
    @Published var controllingPhone = false
    private var syncCancellable: AnyCancellable?
    private let inputController = InputController()
    private let screenViewer = ScreenViewer()
    private var macScreenSender: MacScreenSender?
    private let statusBar = StatusBarController()
    private var tabTimer: Timer?
    private var lastSentTabURL: String?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private let clipboard = ClipboardWatcher()
    private var audioSender: SystemAudioSender?

    // Per-connection encryption: ECDH key exchange, then AES-GCM on every packet.
    private var crypto = CryptoBox()
    private var handshakeDone = false
    /// Whether the paired phone can encrypt side-channel byte transfers.
    private var peerEncSideChannels = false

    static let fixedPort: UInt16 = 52377

    private var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    private var menuBar: MenuBarController?

    func appendLogPublic(_ message: String) { appendLog(message) }

    func start() {
        if menuBar == nil { menuBar = MenuBarController(server: self) }
        Notifier.shared.onLog = { [weak self] message in self?.appendLog(message) }
        Notifier.shared.onReply = { [weak self] id, text in
            guard let self else { return }
            guard self.isPaired else {
                // Don't drop the reply silently — the banner outlives the connection.
                self.appendLog("Reply not sent — phone is disconnected")
                Notifier.shared.show(app: "Bifrost", title: "Reply not delivered",
                                     body: "Your phone is disconnected. Reconnect and try again.")
                return
            }
            self.send(Packet(type: "notification.reply", body: ["id": id, "text": text]))
            self.appendLog("Reply → phone: \(text)")
        }
        Notifier.shared.onAction = { [weak self] key, index in
            guard let self, self.isPaired else { return }
            self.send(Packet(type: "notification.action", body: ["key": key, "index": index]))
            self.appendLog("Notification action → phone")
        }
        Notifier.shared.onDismissAction = { [weak self] key in
            guard let self, self.isPaired else { return }
            self.send(Packet(type: "notification.dismiss", body: ["key": key]))
            self.appendLog("Dismissed a notification on the phone")
        }
        Notifier.shared.onCallAction = { [weak self] action in
            guard let self, self.isPaired else { return }
            self.send(Packet(type: "call.action", body: ["action": action]))
            self.appendLog(action == "silence" ? "Silenced the ringing phone" : "Declined the call")
        }
        Notifier.shared.requestAuthorization()

        // Folder sync: broadcast our manifest / pull files over the control channel.
        if syncCancellable == nil {
            syncCancellable = syncFolder.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        syncFolder.onLog = { [weak self] message in self?.appendLog(message) }
        syncFolder.sendManifestPacket = { [weak self] files in
            guard let self, self.isPaired else { return }
            self.send(Packet(type: "sync.manifest", body: ["files": files]))
        }
        syncFolder.requestPull = { [weak self] rel in
            guard let self, self.isPaired else { return }
            self.send(Packet(type: "sync.pull", body: ["p": rel]))
        }

        // Universal Control: drive a cursor on the phone with the Mac's mouse+keyboard.
        universalControl.isPaired = { [weak self] in self?.isPaired ?? false }
        universalControl.onLog = { [weak self] message in self?.appendLog(message) }
        universalControl.onSend = { [weak self] type, body in
            guard let self, self.isPaired else { return }
            self.send(Packet(type: type, body: body))
        }
        universalControl.onActiveChange = { [weak self] on in
            self?.controllingPhone = on
            self?.menuBar?.updateControlling(on)
        }
        universalControl.start()

        micReceiver.onLog = { [weak self] message in self?.appendLog(message) }
        inputController.onLog = { [weak self] message in self?.appendLog(message) }
        screenViewer.onLog = { [weak self] message in self?.appendLog(message) }
        screenViewer.onClosed = { [weak self] in self?.screenViewing = false }
        screenViewer.onInput = { [weak self] action, x, y, x2, y2, ms in
            guard let self, self.isPaired else { return }
            var body: [String: Any] = ["a": action, "x": x, "y": y]
            if action == "swipe" {
                body["x2"] = x2; body["y2"] = y2; body["ms"] = ms
            }
            self.send(Packet(type: "screen.input", body: body))
        }
        screenViewer.onKey = { [weak self] text, special in
            guard let self, self.isPaired else { return }
            var body: [String: Any] = [:]
            if let text { body["text"] = text }
            if let special { body["special"] = special }
            self.send(Packet(type: "screen.key", body: body))
        }
        // Drag files ONTO the mirror window → send them to the phone.
        screenViewer.onDropFiles = { [weak self] urls in
            guard let self, self.isPaired else { return }
            for url in urls { self.sendFile(url: url) }
        }
        // Option-drag OUT of the mirror window → pull the phone's latest photo.
        screenViewer.onPullFile = { [weak self] completion in
            self?.pullLatestImage(completion)
        }

        // Handoff-style tab sync: poll the front browser tab and push changes to the phone.
        tabTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMacBrowserTab() }
        }
        clipboard.onChange = { [weak self] content in
            guard let self, self.autoSyncClipboard, self.isPaired else { return }
            self.send(Packet(type: "clipboard", body: ["content": content]))
            self.appendLog("Clipboard → phone (\(content.count) chars)")
        }
        clipboard.start()

        do {
            // Bind a fixed port so connect-by-address (e.g. Tailscale) has a known
            // target. Fall back to a system-assigned port if it's taken.
            let listener: NWListener
            if let fixed = NWEndpoint.Port(rawValue: Self.fixedPort),
               let bound = try? NWListener(using: .tcp, on: fixed) {
                listener = bound
            } else {
                listener = try NWListener(using: .tcp)
            }
            listener.service = NWListener.Service(name: deviceName, type: "_macdroid._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.port = listener.port?.rawValue
                        self?.statusText = "Advertising as “\(self?.deviceName ?? "Mac")”"
                    case .failed(let error):
                        self?.statusText = "Listener failed: \(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] newConnection in
                Task { @MainActor in
                    self?.accept(newConnection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            statusText = "Could not start listener: \(error.localizedDescription)"
        }
    }

    private func accept(_ newConnection: NWConnection) {
        // v1 supports a single phone: a new connection replaces the old one.
        // Silence the old connection's handler first — its .cancelled event would
        // otherwise arrive later and tear down the connection that replaced it.
        if let old = connection {
            old.stateUpdateHandler = nil
            old.cancel()
        }
        resetSessionState()
        connection = newConnection
        buffer = Data()
        crypto = CryptoBox()
        handshakeDone = false
        peerEncSideChannels = false
        appendLog("Incoming connection from \(newConnection.endpoint)")

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            Task { @MainActor in
                guard let self, let newConnection, self.connection === newConnection else { return }
                switch state {
                case .ready:
                    self.statusText = "Phone connected — securing…"
                    // Send our ephemeral public key (plaintext) to start the key exchange.
                    self.sendRaw(self.crypto.publicKeyBase64 + "\n")
                case .failed(let error):
                    self.appendLog("Connection failed: \(error.localizedDescription)")
                    self.dropConnection()
                case .cancelled:
                    self.dropConnection()
                default:
                    break
                }
            }
        }
        newConnection.start(queue: .main)
        receiveLoop(on: newConnection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainBuffer()
                }
                if isComplete || error != nil {
                    self.appendLog("Phone disconnected")
                    self.dropConnection()
                } else {
                    self.receiveLoop(on: connection)
                }
            }
        }
    }

    private func drainBuffer() {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if !handshakeDone {
                // First line is the peer's public key.
                guard let text = String(data: line, encoding: .utf8),
                      crypto.deriveKey(peerBase64: text) else {
                    appendLog("Key exchange failed — dropping connection")
                    dropConnection()
                    return
                }
                handshakeDone = true
                statusText = "Encrypted — waiting for pairing"
                appendLog("Secure channel established (AES-256-GCM)")
                send(Packet(type: "identity", body: ["name": deviceName, "device": "mac", "enc": true]))
                continue
            }
            guard let base64 = String(data: line, encoding: .utf8),
                  let plaintext = crypto.open(base64),
                  let packet = Packet.decode(plaintext) else {
                appendLog("Dropped an undecryptable packet")
                continue
            }
            handle(packet)
        }
    }

    /// Send bytes on the wire without framing/encryption (used for the KEX line).
    private func sendRaw(_ text: String) {
        guard let connection else { return }
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func handle(_ packet: Packet) {
        switch packet.type {
        case "identity":
            connectedDeviceName = packet.body["name"] as? String ?? "Android device"
            // Peer advertises whether it can encrypt side-channel transfers.
            peerEncSideChannels = packet.body["enc"] as? Bool ?? false
            appendLog("Identified: \(connectedDeviceName!)\(peerEncSideChannels ? " · secure transfers" : "")")

        case "pair.request":
            handlePairRequest(packet)

        case "clipboard":
            guard isPaired, let content = packet.body["content"] as? String else { return }
            clipboard.setClipboard(content)
            lastReceivedClipboard = content
            appendLog("Clipboard ← phone (\(content.count) chars)")

        case "ping":
            guard isPaired else { return }
            NSSound.beep()
            appendLog("Ping from phone")

        case "heartbeat":
            // Keep-alive traffic — newer phones piggyback the battery level on it.
            if let batt = packet.body["batt"] as? Int {
                applyBattery(batt, charging: packet.body["charging"] as? Bool ?? false)
            }

        case "battery":
            guard isPaired, let batt = packet.body["batt"] as? Int else { return }
            applyBattery(batt, charging: packet.body["charging"] as? Bool ?? false)

        case "notification":
            guard isPaired else { return }
            let app = packet.body["app"] as? String ?? "Phone"
            let title = packet.body["title"] as? String ?? ""
            let text = packet.body["text"] as? String ?? ""
            let id = packet.body["id"] as? String ?? ""
            let canReply = packet.body["canReply"] as? Bool ?? false
            let key = packet.body["key"] as? String ?? ""
            let actions = packet.body["actions"] as? [String] ?? []
            Notifier.shared.show(app: app, title: title, body: text, id: id, canReply: canReply,
                                 key: key, actions: actions)
            appendLog("Notification from \(app)\(canReply ? " (repliable)" : "")")

        case "call.state":
            guard isPaired, let state = packet.body["state"] as? String else { return }
            handleCallState(state,
                            name: packet.body["name"] as? String ?? "",
                            number: packet.body["number"] as? String ?? "",
                            muted: packet.body["muted"] as? Bool,
                            speaker: packet.body["speaker"] as? Bool)

        case "notification.dismiss":
            guard isPaired else { return }
            let id = packet.body["id"] as? String ?? ""
            Notifier.shared.dismiss(id: id)

        case "notification.reply.result":
            guard isPaired else { return }
            let ok = packet.body["ok"] as? Bool ?? false
            if !ok {
                Notifier.shared.show(app: "Bifrost", title: "Reply not delivered",
                                     body: "That notification is no longer available on your phone.")
                appendLog("Reply not delivered — notification gone on phone")
            }

        case "media.now":
            guard isPaired else { return }
            let title = packet.body["title"] as? String ?? ""
            let artist = packet.body["artist"] as? String ?? ""
            let playing = packet.body["playing"] as? Bool ?? false
            // Art only comes when the track changes; keep the previous one otherwise.
            var art = nowPlaying?.art
            if let b64 = packet.body["art"] as? String,
               let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
                art = image
            } else if nowPlaying?.title != title {
                art = nil
            }
            nowPlaying = NowPlaying(title: title, artist: artist, playing: playing, art: art)

        case "media.none":
            nowPlaying = nil

        case "input":
            guard isPaired else { return }
            inputController.handle(packet.body) // no logging — these arrive ~60×/second

        case "browse":
            guard isPaired,
                  let urlString = packet.body["url"] as? String,
                  urlString.hasPrefix("http")
            else { return }
            let title = packet.body["title"] as? String ?? ""
            phoneTabURL = urlString
            phoneTabTitle = title
            statusBar.show(url: urlString, title: title)

        case "url":
            guard isPaired,
                  let urlString = packet.body["url"] as? String,
                  let url = URL(string: urlString),
                  ["http", "https"].contains(url.scheme?.lowercased())
            else { return }
            NSWorkspace.shared.open(url)
            appendLog("Opened link from phone: \(urlString)")

        case "command":
            guard isPaired, let action = packet.body["action"] as? String else { return }
            runCommand(action)

        case "present":
            guard isPaired, let action = packet.body["action"] as? String else { return }
            presentationKey(action)

        case "audio.start":
            guard isPaired,
                  packet.body["direction"] as? String == "mic",
                  let port = packet.body["port"] as? Int,
                  let host = remoteHost()
            else { return }
            let sampleRate = packet.body["sampleRate"] as? Double ?? 16000
            let channels = packet.body["channels"] as? Int ?? 1
            let micEnc = (packet.body["enc"] as? Bool) ?? false
            micReceiver.start(host: host, port: UInt16(port), sampleRate: sampleRate, channels: channels, cipher: micEnc ? crypto : nil)

        case "audio.stop":
            if packet.body["direction"] as? String == "mic" {
                micReceiver.stop()
            }

        case "screen.start":
            guard isPaired,
                  let width = packet.body["width"] as? Int,
                  let height = packet.body["height"] as? Int,
                  let port = packet.body["port"] as? Int,
                  let host = remoteHost()
            else { return }
            let scrEnc = (packet.body["enc"] as? Bool) ?? false
            screenViewer.start(host: host, port: UInt16(port), width: width, height: height, cipher: scrEnc ? crypto : nil)
            screenViewing = true
            appendLog("Viewing phone screen (\(width)×\(height))")

        case "screen.stop":
            screenViewer.stop()
            screenViewing = false

        case "macscreen.request":
            guard isPaired else { return }
            startMirrorToPhone()

        case "gallery.thumbs":
            guard isPaired else { return }
            galleryHasMore = (packet.body["hasMore"] as? Bool) ?? false
            let items = packet.body["items"] as? [[String: Any]] ?? []
            let parsed: [(Int, String)] = items.compactMap {
                guard let id = $0["id"] as? Int else { return nil }
                return (id, ($0["name"] as? String) ?? "photo")
            }
            // Empty page (no port) → just stop the spinner.
            guard let port = packet.body["port"] as? Int, let host = remoteHost(), !parsed.isEmpty else {
                galleryLoading = false
                return
            }
            let galEnc = (packet.body["enc"] as? Bool) ?? false
            receiveGalleryThumbs(host: host, port: UInt16(port), items: parsed, enc: galEnc)

        case "fs.entries":
            guard isPaired else { return }
            fileBrowsing = true
            fsNeedsPermission = (packet.body["needsPermission"] as? Bool) ?? false
            fsPath = packet.body["path"] as? String ?? fsPath
            fsParent = packet.body["parent"] as? String ?? ""
            let entries = packet.body["entries"] as? [[String: Any]] ?? []
            fsEntries = entries.compactMap {
                guard let name = $0["name"] as? String else { return nil }
                return FileEntry(name: name, isDir: ($0["dir"] as? Bool) ?? false, size: ($0["size"] as? Int) ?? 0)
            }

        case "macscreen.stop":
            stopMirrorToPhone(notifyPhone: false)

        case "file.offer":
            guard isPaired,
                  let name = packet.body["name"] as? String,
                  let size = packet.body["size"] as? Int,
                  let port = packet.body["port"] as? Int,
                  let host = remoteHost()
            else { return }
            let isPull = (packet.body["pull"] as? Bool) ?? false
            let enc = (packet.body["enc"] as? Bool) ?? false
            let syncRel = (packet.body["sync"] as? Bool) == true ? (packet.body["p"] as? String) : nil
            let mtime = (packet.body["mtime"] as? NSNumber)?.int64Value
            receiveFile(name: name, size: size, host: host, port: UInt16(port), pull: isPull, enc: enc, syncRel: syncRel, syncMtime: mtime)

        case "clipboard.image":
            guard isPaired,
                  let name = packet.body["name"] as? String,
                  let size = packet.body["size"] as? Int,
                  let port = packet.body["port"] as? Int,
                  let host = remoteHost()
            else { return }
            let enc = (packet.body["enc"] as? Bool) ?? false
            receiveFile(name: name, size: size, host: host, port: UInt16(port), clipboardImage: true, enc: enc)

        case "control.unavailable":
            guard isPaired else { return }
            universalControl.exitIfActive() // phone can't accept control — don't hide our cursor
            appendLog("Phone control unavailable — enable “Bifrost screen control” on the phone")

        case "control.exit":
            guard isPaired else { return }
            universalControl.exitIfActive() // user slid off the phone's left edge — back to the Mac

        case "sync.manifest":
            guard isPaired else { return }
            let files = packet.body["files"] as? [[String: Any]] ?? []
            syncFolder.applyRemoteManifest(files)

        case "sync.pull":
            guard isPaired, let rel = packet.body["p"] as? String else { return }
            sendSyncFile(rel: rel)

        default:
            appendLog("Unknown packet: \(packet.type)")
        }
    }

    /// Send a file from our sync folder to the phone, tagged so it lands in the
    /// phone's sync folder with our modification time preserved.
    private func sendSyncFile(rel: String) {
        guard let url = SyncFolderManager.sanitize(rel, under: syncFolder.folderURL),
              FileManager.default.fileExists(atPath: url.path) else { return }
        sendFile(url: url, syncRel: rel)
    }

    // MARK: - Pairing

    private func tokenKey(for device: String) -> String { "pairToken.\(device)" }

    private func handlePairRequest(_ packet: Packet) {
        let device = connectedDeviceName ?? "phone"

        if let token = packet.body["token"] as? String,
           let stored = UserDefaults.standard.string(forKey: tokenKey(for: device)),
           token == stored {
            send(Packet(type: "pair.accept", body: ["token": token]))
            isPaired = true
            statusText = "Paired with \(device)"
            appendLog("Auto-paired with remembered device \(device)")
            return
        }

        if let code = packet.body["code"] as? String {
            pendingPairCode = code
            statusText = "Pairing request from \(device)"
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Token we don't recognize and no code: make the phone fall back to the code flow.
            send(Packet(type: "pair.reject"))
            appendLog("Rejected unknown pairing token from \(device)")
        }
    }

    func acceptPairing() {
        guard pendingPairCode != nil else { return }
        let device = connectedDeviceName ?? "phone"
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: tokenKey(for: device))
        send(Packet(type: "pair.accept", body: ["token": token]))
        pendingPairCode = nil
        isPaired = true
        statusText = "Paired with \(device)"
        appendLog("Pairing accepted — device remembered for silent reconnects")
    }

    func rejectPairing() {
        send(Packet(type: "pair.reject"))
        pendingPairCode = nil
        appendLog("Pairing rejected")
    }

    // MARK: - Phone battery

    /// SF Symbol for a battery level, shared by the menu bar and the header.
    static func batterySymbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func applyBattery(_ batt: Int, charging: Bool) {
        let level = max(0, min(100, batt))
        phoneBattery = level
        phoneCharging = charging
        menuBar?.updateBattery(level: level, charging: charging)

        // Episode resets: leaving the state re-arms its alert.
        if charging || level > 20 { lowBatteryAlerted = false }
        if !charging || level < 100 { fullBatteryAlerted = false }

        if level <= 20, !charging, !lowBatteryAlerted {
            lowBatteryAlerted = true
            Notifier.shared.show(app: "Bifrost", title: "Phone battery low — \(level)%",
                                 body: "Plug your phone in when you get a chance.")
            appendLog("Phone battery low — \(level)%")
        }
        if level == 100, charging, !fullBatteryAlerted {
            fullBatteryAlerted = true
            Notifier.shared.show(app: "Bifrost", title: "Phone fully charged",
                                 body: "100% — you can unplug it.")
            appendLog("Phone fully charged — still plugged in")
        }
    }

    // MARK: - Incoming calls

    private func handleCallState(_ state: String, name: String, number: String,
                                 muted: Bool?, speaker: Bool?) {
        let display = name.isEmpty ? number : name
        let wasRinging = callState == "ringing"
        callState = state
        callerDisplay = display
        // Optional live mic/speaker state, present during offhook. Absent fields
        // leave the last-known value untouched (never flip a toggle on nothing).
        if let muted { callMuted = muted }
        if let speaker { callSpeaker = speaker }

        switch state {
        case "ringing":
            guard !wasRinging else { return } // repeated ringing updates: banner already up
            Notifier.shared.showCall(name: name, number: number)
            // Pause whatever the Mac is playing while the phone rings (v1: no auto-resume).
            postMediaKey(16) // NX_KEYTYPE_PLAY
            appendLog("Incoming call — \(display.isEmpty ? "unknown caller" : display)")
        case "offhook":
            Notifier.shared.dismissCall()
            if wasRinging { appendLog("Call answered on the phone") }
        default: // "idle"
            Notifier.shared.dismissCall()
            if wasRinging { appendLog("Call ended") }
            callerDisplay = ""
            callMuted = false
            callSpeaker = false
        }
    }

    /// Send an ongoing-call control to the phone (hangup / mute / unmute /
    /// speaker_on / speaker_off). We DON'T optimistically flip callMuted/
    /// callSpeaker — the phone re-emits `call.state` with the real resulting
    /// values, so the toggle can't lie if the OS refused the change.
    func callAction(_ action: String) {
        guard isPaired else { return }
        send(Packet(type: "call.action", body: ["action": action]))
        let label: String
        switch action {
        case "hangup":      label = "Hung up the call"
        case "mute":        label = "Muted the call mic"
        case "unmute":      label = "Unmuted the call mic"
        case "speaker_on":  label = "Turned speakerphone on"
        case "speaker_off": label = "Turned speakerphone off"
        default:            label = "Call action → phone"
        }
        appendLog(label)
    }

    // MARK: - Actions

    func sendClipboardNow() {
        guard isPaired, let content = ClipboardWatcher.current() else { return }
        send(Packet(type: "clipboard", body: ["content": content]))
        appendLog("Clipboard → phone (\(content.count) chars)")
    }

    func pingPhone() {
        guard isPaired else { return }
        send(Packet(type: "ping", body: ["message": "Ping from \(deviceName)"]))
        appendLog("Ping → phone")
    }

    func mediaCommand(_ action: String) {
        guard isPaired else { return }
        send(Packet(type: "media.command", body: ["action": action]))
    }

    /// Presentation clicker: inject the key that advances/controls a running
    /// slideshow (Keynote, PowerPoint, Google Slides, PDF). Needs Accessibility.
    private func presentationKey(_ action: String) {
        let keyCode: CGKeyCode
        switch action {
        case "next":  keyCode = 124 // →
        case "prev":  keyCode = 123 // ←
        case "black": keyCode = 11  // B — blank the screen (PowerPoint/Keynote)
        case "start": keyCode = 96  // F5 — start slideshow (PowerPoint)
        case "end":   keyCode = 53  // Esc — end slideshow
        default: return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
        appendLog("Presenter: \(action)")
    }

    func requestPhoneScreen() {
        guard isPaired else { return }
        send(Packet(type: "screen.request"))
        appendLog("Asked phone to share its screen — accept on the phone")
    }

    @Published var desktopStarting = false

    private nonisolated static var adbPath: String {
        let candidates = [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
    private nonisolated static var hasADB: Bool { FileManager.default.isExecutableFile(atPath: adbPath) }
    private nonisolated static var scrcpyPath: String? {
        ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private nonisolated static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Desktop Mode: open a phone-powered Android desktop in its own window via
    /// scrcpy's virtual display. Auto-reconnects ADB first (so it works even if
    /// the wireless-debug link dropped), then launches scrcpy.
    func launchDesktopMode() {
        guard !desktopStarting else { return }
        guard let scrcpy = Self.scrcpyPath else {
            offerDesktopModeInstall()
            return
        }
        desktopStarting = true
        appendLog("Desktop Mode: connecting to the phone over ADB…")

        Task.detached { [weak self] in
            let ok = Self.ensureAdbDevice()
            await MainActor.run {
                guard let self else { return }
                self.desktopStarting = false
                guard ok else {
                    self.appendLog("Desktop Mode: no phone over ADB. Turn on Settings → Developer options → Wireless debugging, then try again.")
                    return
                }
                self.spawnScrcpy(scrcpy)
            }
        }
    }

    /// scrcpy is missing: ask permission, then install it (and ADB platform-tools
    /// if needed) with Homebrew, and start Desktop Mode when done.
    private func offerDesktopModeInstall() {
        guard let brew = Self.brewPath else {
            appendLog("Desktop Mode needs scrcpy, and Homebrew isn't installed — get Homebrew from brew.sh, then run: brew install scrcpy")
            let alert = NSAlert()
            alert.messageText = "Desktop Mode needs scrcpy"
            alert.informativeText = "Bifrost can't install it automatically because Homebrew isn't on this Mac. Install Homebrew from brew.sh, then run “brew install scrcpy” in Terminal — Desktop Mode will work right after."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install scrcpy for Desktop Mode?"
        alert.informativeText = Self.hasADB
            ? "Desktop Mode is powered by scrcpy (free, open source). Bifrost will run “brew install scrcpy” for you — it usually takes a couple of minutes, then Desktop Mode starts automatically."
            : "Desktop Mode is powered by scrcpy and ADB (both free, open source). Bifrost will install them with Homebrew for you — it usually takes a couple of minutes, then Desktop Mode starts automatically."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            appendLog("Desktop Mode: scrcpy install cancelled")
            return
        }
        autoLaunchAfterInstall = true
        installDesktopModeTools(brew: brew)
    }

    private var autoLaunchAfterInstall = false

    private func installDesktopModeTools(brew: String) {
        desktopStarting = true
        appendLog("Installing scrcpy with Homebrew — this can take a few minutes…")
        Task.detached { [weak self] in
            var (status, output) = Self.runBrew(brew, ["install", "scrcpy"])
            if status == 0 && !Self.hasADB {
                await MainActor.run { self?.appendLog("Installing ADB platform-tools…") }
                (status, output) = Self.runBrew(brew, ["install", "--cask", "android-platform-tools"])
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.desktopStarting = false
                if status == 0, Self.scrcpyPath != nil {
                    self.appendLog("scrcpy installed ✓")
                    if self.autoLaunchAfterInstall { self.launchDesktopMode() }
                } else {
                    let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                    self.appendLog("Install failed (\(tail)) — run “brew install scrcpy” in Terminal instead.")
                }
                self.refreshDesktopSetup()
            }
        }
    }

    private nonisolated static func runBrew(_ brew: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (1, error.localizedDescription) }
        // Drain the pipe before waiting so a chatty install can't deadlock on a full buffer.
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    // MARK: USB link

    /// Connect over a USB cable: ADB reverse-tunnels the Mac's fixed port onto
    /// the phone's localhost, so the phone reaches this Mac with no network at
    /// all via Connect by address → 127.0.0.1.
    func enableUSBLink() {
        appendLog("USB link: looking for the phone over ADB…")
        Task.detached { [weak self] in
            let ok = Self.ensureAdbDevice()
            if ok {
                _ = Self.runADB(["reverse", "tcp:\(Self.fixedPort)", "tcp:\(Self.fixedPort)"])
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.appendLog("USB link ready ✓ — an already-paired phone connects by itself within ~10s. First time? On the phone: Connect by address → 127.0.0.1:\(Self.fixedPort)")
                } else {
                    self.appendLog("USB link: no phone over ADB. Plug in the cable, enable USB debugging (Settings → Developer options), then try again.")
                }
            }
        }
    }

    // MARK: Desktop Mode setup guide

    @Published var setupScrcpyReady = false
    @Published var setupPhoneReady = false
    @Published var setupPairingEndpoint: String?
    @Published var setupPairing = false
    @Published var setupMessage: String?

    /// One status pass for the setup guide: tools present? phone reachable over
    /// ADB? is the phone currently showing its pairing dialog (mDNS advertises it)?
    func refreshDesktopSetup() {
        Task.detached { [weak self] in
            let scrcpyReady = Self.scrcpyPath != nil
            var phoneReady = false
            var pairingEndpoint: String?
            if Self.hasADB {
                func deviceListed() -> Bool {
                    let out = Self.runADB(["devices"]) ?? ""
                    return out.split(separator: "\n").dropFirst().contains { $0.hasSuffix("\tdevice") }
                }
                phoneReady = deviceListed()
                let services = Self.runADB(["mdns", "services"]) ?? ""
                pairingEndpoint = Self.endpoint(in: services, service: "_adb-tls-pairing")
                if !phoneReady, let connect = Self.endpoint(in: services, service: "_adb-tls-connect") {
                    _ = Self.runADB(["connect", connect]) // already-paired phone: reconnect silently
                    phoneReady = deviceListed()
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.setupScrcpyReady = scrcpyReady
                self.setupPhoneReady = phoneReady
                self.setupPairingEndpoint = pairingEndpoint
            }
        }
    }

    private nonisolated static func endpoint(in services: String, service: String) -> String? {
        guard let line = services.split(separator: "\n").first(where: { $0.contains(service) }),
              let last = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last,
              last.contains(":")
        else { return nil }
        return String(last)
    }

    /// Pair with the endpoint the phone's "Pair device with pairing code" dialog advertises.
    func pairPhone(code: String) {
        guard let endpoint = setupPairingEndpoint, !setupPairing else { return }
        setupPairing = true
        setupMessage = nil
        Task.detached { [weak self] in
            let out = Self.runADB(["pair", endpoint, code]) ?? ""
            let ok = out.lowercased().contains("successfully paired")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.setupPairing = false
                self.setupMessage = ok ? "Paired ✓" : "Pairing failed — check the code on the phone and try again."
                if ok { self.appendLog("Phone paired for Desktop Mode") }
            }
            if ok {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { [weak self] in self?.refreshDesktopSetup() }
            }
        }
    }

    /// Install scrcpy/ADB from inside the setup guide (the guide is the consent).
    func installDesktopEngine() {
        guard Self.scrcpyPath == nil, !desktopStarting else { return }
        guard let brew = Self.brewPath else {
            setupMessage = "Homebrew isn't installed — get it from brew.sh, then run: brew install scrcpy"
            return
        }
        autoLaunchAfterInstall = false // the guide has its own Open Desktop button
        installDesktopModeTools(brew: brew)
    }

    /// Ensure an ADB device is present; if not, restart the server and try to
    /// (re)connect to a wireless-debug endpoint that mDNS is advertising.
    private nonisolated static func ensureAdbDevice() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else { return false }
        func hasDevice() -> Bool {
            let out = runADB(["devices"]) ?? ""
            return out.split(separator: "\n").dropFirst().contains { $0.hasSuffix("\tdevice") }
        }
        if hasDevice() { return true }
        _ = runADB(["reconnect", "offline"])
        _ = runADB(["kill-server"])
        _ = runADB(["start-server"])
        for _ in 0..<8 {
            if hasDevice() { return true }
            if let services = runADB(["mdns", "services"]),
               let line = services.split(separator: "\n").first(where: { $0.contains("_adb-tls-connect") }),
               let endpoint = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last {
                _ = runADB(["connect", String(endpoint)])
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return hasDevice()
    }

    private nonisolated static func runADB(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private func spawnScrcpy(_ scrcpy: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpy)
        process.arguments = [
            "--new-display=1600x900/160", "--stay-awake", "--no-audio",
            "--window-title=Bifrost Desktop",
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        env["ADB"] = Self.adbPath
        process.environment = env

        // scrcpy logs "New display: …(id=N)" to stderr. On Samsung, a fresh virtual
        // display comes up EMPTY (the DeX home doesn't auto-attach), so we watch for
        // that id and place a launcher on the display ourselves — otherwise the
        // Desktop Mode window is just a black screen.
        let errPipe = Pipe()
        process.standardError = errPipe
        let launcherStarted = LockedFlag()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard text.contains("New display"),
                  let r = text.range(of: #"id=(\d+)"#, options: .regularExpression),
                  let id = Int(text[r].dropFirst(3)) else { return }
            if launcherStarted.setOnce() {
                Self.startDesktopLauncher(displayId: id)
            }
        }
        process.terminationHandler = { [weak self] _ in
            errPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.appendLog("Desktop Mode window closed") }
        }
        do {
            try process.run()
            appendLog("Desktop Mode open — a desktop launcher will appear in the window")
        } catch {
            appendLog("Desktop Mode failed to start: \(error.localizedDescription)")
        }
    }

    /// Put a home/launcher on the freshly-created virtual display. Samsung's DeX
    /// SecondaryLauncher gives a proper desktop; on non-Samsung devices this is a
    /// harmless no-op and the display still hosts any app launched onto it.
    private nonisolated static func startDesktopLauncher(displayId: Int) {
        // Let the display settle, then push the DeX home onto it (twice — the first
        // delivery sometimes only wakes the display; the second brings it forward).
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            for _ in 0..<2 {
                _ = runADB(["shell", "am", "start-activity", "--display", "\(displayId)",
                            "-n", "com.sec.android.app.launcher/com.honeyspace.dexservice.SecondaryLauncher"])
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
    }

    /// Toggle Universal Control (drive the phone with the Mac's mouse+keyboard).
    func toggleUniversalControl() {
        guard isPaired else { return }
        universalControl.toggle()
    }

    func startMirrorToPhone() {
        guard isPaired, macScreenSender == nil else { return }
        let sender = MacScreenSender()
        macScreenSender = sender
        sender.onLog = { [weak self] message in self?.appendLog(message) }
        sender.onStopped = { [weak self] in
            self?.macScreenSender = nil
            self?.mirroringToPhone = false
        }
        let enc = peerEncSideChannels && crypto.isReady
        sender.start(cipher: enc ? crypto : nil) { [weak self] width, height, port in
            guard let self else { return }
            var body: [String: Any] = ["width": width, "height": height, "port": port]
            if enc { body["enc"] = true }
            self.send(Packet(type: "macscreen.start", body: body))
            self.mirroringToPhone = true
            self.appendLog("Mirroring Mac screen to phone (\(width)×\(height))")
        }
    }

    func stopMirrorToPhone(notifyPhone: Bool = true) {
        if notifyPhone { send(Packet(type: "macscreen.stop")) }
        macScreenSender?.stop()
        macScreenSender = nil
        mirroringToPhone = false
    }

    func stopPhoneScreen() {
        send(Packet(type: "screen.stop"))
        screenViewer.stop()
        screenViewing = false
    }

    func sendClipboardURL() {
        guard isPaired else { return }
        guard let content = ClipboardWatcher.current()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: content),
              ["http", "https"].contains(url.scheme?.lowercased())
        else {
            appendLog("Clipboard doesn't contain a link")
            return
        }
        send(Packet(type: "url", body: ["url": content]))
        appendLog("Link → phone: \(content)")
    }

    // MARK: - Mac audio → phone (for the phone's Bluetooth output)

    func startSpeakerStream() {
        guard isPaired, audioSender == nil else { return }
        let sender = SystemAudioSender()
        audioSender = sender
        sender.onLog = { [weak self] message in self?.appendLog(message) }
        sender.onStopped = { [weak self] in
            self?.audioSender = nil
            self?.speakerStreaming = false
        }
        let enc = peerEncSideChannels && crypto.isReady
        sender.start(cipher: enc ? crypto : nil) { [weak self] port in
            guard let self else { return }
            var body: [String: Any] = [
                "direction": "speaker",
                "sampleRate": SystemAudioSender.sampleRate,
                "channels": SystemAudioSender.channels,
                "port": port,
            ]
            if enc { body["enc"] = true }
            self.send(Packet(type: "audio.start", body: body))
            self.speakerStreaming = true
            self.appendLog("Streaming Mac audio to phone")
        }
    }

    func stopSpeakerStream() {
        guard audioSender != nil else { return }
        send(Packet(type: "audio.stop", body: ["direction": "speaker"]))
        audioSender?.stop()
        audioSender = nil
        speakerStreaming = false
        appendLog("Mac audio stream stopped")
    }

    // MARK: - Tab sync (Mac → phone)

    private func pollMacBrowserTab() {
        guard isPaired else { return }
        Task.detached { [weak self] in
            guard let tab = Self.queryFrontBrowserTab() else { return }
            await self?.sendMacTab(url: tab.url, title: tab.title)
        }
    }

    private func sendMacTab(url: String, title: String) {
        guard isPaired, url != lastSentTabURL else { return }
        lastSentTabURL = url
        send(Packet(type: "browse", body: ["url": url, "title": title, "source": "mac"]))
    }

    /// Reads the active tab of a *running* browser (never launches one).
    /// The first call triggers a one-time macOS Automation permission prompt.
    private nonisolated static func queryFrontBrowserTab() -> (url: String, title: String)? {
        let running = NSWorkspace.shared.runningApplications
        let script: String
        if running.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            script = "tell application \"Google Chrome\" to if (count of windows) > 0 then return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
        } else if running.contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            script = "tell application \"Safari\" to if (count of documents) > 0 then return (URL of front document) & linefeed & (name of front document)"
        } else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard
            let data = try? output.fileHandleForReading.readToEnd(),
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let url = lines.first, url.hasPrefix("http") else { return nil }
        return (url, lines.count > 1 ? lines[1] : "")
    }

    // MARK: - Remote commands from the phone

    private func runCommand(_ action: String) {
        appendLog("Command from phone: \(action)")
        switch action {
        case "lock":
            runProcess("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])
        case "sleep":
            runProcess("/usr/bin/pmset", ["sleepnow"])
        case "mute":
            osascript("set volume output muted (not (output muted of (get volume settings)))")
        case "volume_up":
            osascript("set volume output volume (((output volume of (get volume settings)) + 10))")
        case "volume_down":
            osascript("set volume output volume (((output volume of (get volume settings)) - 10))")
        case "playpause":
            postMediaKey(16) // NX_KEYTYPE_PLAY
        case "screenshot":
            takeAndSendScreenshot()
        default:
            appendLog("Unknown command: \(action)")
        }
    }

    private func runProcess(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            appendLog("Command failed: \(error.localizedDescription)")
        }
    }

    private func osascript(_ script: String) {
        runProcess("/usr/bin/osascript", ["-e", script])
    }

    private func postMediaKey(_ key: Int32) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((Int(key) << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    private func takeAndSendScreenshot() {
        let path = NSTemporaryDirectory() + "macdroid-screenshot.png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", path]
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.sendFile(url: URL(fileURLWithPath: path))
                } else {
                    self.appendLog("Screenshot failed — grant Screen Recording permission to your terminal in System Settings")
                }
            }
        }
        do {
            try process.run()
        } catch {
            appendLog("Screenshot failed: \(error.localizedDescription)")
        }
    }

    // MARK: - File transfer: sending (Mac → phone)

    func sendFile(url: URL, toDir dir: String? = nil, syncRel: String? = nil) {
        guard isPaired else { return }
        let name = url.lastPathComponent
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.intValue,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            appendLog("Cannot read \(name)")
            return
        }
        let mtimeMs = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) }
        let enc = peerEncSideChannels && crypto.isReady

        do {
            let fileListener = try NWListener(using: .tcp)
            fileListener.newConnectionHandler = { [weak self] transferConnection in
                transferConnection.start(queue: .main)
                Task { @MainActor in
                    self?.stream(handle: handle, name: name, size: size, over: transferConnection, listener: fileListener, enc: enc)
                }
            }
            fileListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let filePort = fileListener.port?.rawValue else { return }
                        var offer: [String: Any] = ["name": name, "size": size, "port": Int(filePort)]
                        if let dir { offer["dir"] = dir }
                        if enc { offer["enc"] = true }
                        if let syncRel { offer["sync"] = true; offer["p"] = syncRel; if let mtimeMs { offer["mtime"] = mtimeMs } }
                        self.send(Packet(type: "file.offer", body: offer))
                        self.transferStatus = "Sending \(name)…"
                        self.appendLog("Offering \(name) (\(Self.formatBytes(size))) on port \(filePort)")
                    case .failed(let error):
                        self.appendLog("File listener failed: \(error.localizedDescription)")
                        self.transferStatus = nil
                    default:
                        break
                    }
                }
            }
            fileListener.start(queue: .main)
        } catch {
            appendLog("Could not open file channel: \(error.localizedDescription)")
        }
    }

    private func stream(handle: FileHandle, name: String, size: Int, over transferConnection: NWConnection, listener fileListener: NWListener, enc: Bool = false) {
        var sent = 0

        func sendNextChunk() {
            let plainChunk = handle.readData(ofLength: 65536)
            if plainChunk.isEmpty {
                transferConnection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    Task { @MainActor in
                        transferConnection.cancel()
                        fileListener.cancel()
                        self.transferStatus = nil
                        self.appendLog("Sent \(name) ✓")
                    }
                })
                try? handle.close()
                return
            }
            // Encrypt into a framed record when negotiated; else send raw as before.
            // If encryption was negotiated but sealing fails, abort rather than leak
            // plaintext into a stream the receiver will try to decrypt (desync).
            let chunk: Data
            if enc {
                guard let sealed = SideChannelCrypto.sealRecord(crypto, plainChunk) else {
                    self.appendLog("Encryption failed mid-transfer for \(name)")
                    self.transferStatus = nil
                    transferConnection.cancel()
                    fileListener.cancel()
                    try? handle.close()
                    return
                }
                chunk = sealed
            } else {
                chunk = plainChunk
            }
            transferConnection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if error != nil {
                        self.appendLog("Send of \(name) failed mid-transfer")
                        self.transferStatus = nil
                        transferConnection.cancel()
                        fileListener.cancel()
                        try? handle.close()
                        return
                    }
                    sent += plainChunk.count // progress is over plaintext, not the sealed size
                    self.transferStatus = "Sending \(name)… \(Self.percent(sent, of: size))"
                    sendNextChunk()
                }
            })
        }
        sendNextChunk()
    }

    // MARK: - File transfer: receiving (phone → Mac)

    private func remoteHost() -> NWEndpoint.Host? {
        guard
            let endpoint = connection?.currentPath?.remoteEndpoint,
            case let .hostPort(host, _) = endpoint
        else { return nil }
        return host
    }

    private func receiveFile(name: String, size: Int, host: NWEndpoint.Host, port: UInt16, pull: Bool = false, clipboardImage: Bool = false, enc: Bool = false, syncRel: String? = nil, syncMtime: Int64? = nil) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let decryptor = enc ? FramedDecryptor(crypto) : nil

        // Sync files write atomically (".part" then rename) into the sync folder
        // at their relative path; pulls/clipboard images use a temp dir; normal
        // transfers land in Downloads.
        let syncFinalDest: URL?
        let destination: URL
        if let syncRel {
            guard let dest = SyncFolderManager.sanitize(syncRel, under: syncFolder.folderURL) else {
                appendLog("Sync: refused unsafe path \(syncRel)")
                syncFolder.pullFinished(syncRel, success: false)
                return
            }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            syncFinalDest = dest
            destination = dest.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: destination)
        } else {
            syncFinalDest = nil
            let directory = (pull || clipboardImage)
                ? FileManager.default.temporaryDirectory
                : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            destination = Self.uniqueDestination(in: directory, name: Self.sanitize(name))
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            appendLog("Cannot write to \(destination.path)")
            if pull { completePull(nil) }
            return
        }

        if !pull && !clipboardImage {
            transferStatus = "Receiving \(name)…"
            appendLog("Receiving \(name) (\(Self.formatBytes(size)))")
        }

        let transferConnection = NWConnection(host: host, port: nwPort, using: .tcp)
        var received = 0

        func finish(success: Bool) {
            try? handle.close()
            transferConnection.cancel()
            transferStatus = nil
            if let syncFinalDest, let syncRel {
                if success {
                    syncFolder.backupBeforeOverwrite(syncFinalDest) // keep the old copy recoverable
                    do {
                        try FileManager.default.moveItem(at: destination, to: syncFinalDest)
                        if let syncMtime {
                            try? FileManager.default.setAttributes(
                                [.modificationDate: Date(timeIntervalSince1970: Double(syncMtime) / 1000)],
                                ofItemAtPath: syncFinalDest.path)
                        }
                        appendLog("Sync ← \(syncRel)")
                        syncFolder.pullFinished(syncRel, success: true)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        syncFolder.pullFinished(syncRel, success: false)
                    }
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    syncFolder.pullFinished(syncRel, success: false)
                }
                return
            }
            if success {
                if pull {
                    appendLog("Pulled \(name) from phone")
                    completePull(destination)
                } else if clipboardImage {
                    if let image = NSImage(contentsOf: destination) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects([image])
                        appendLog("Image copied — paste anywhere with ⌘V")
                    } else {
                        appendLog("Received image but couldn't read it")
                    }
                    try? FileManager.default.removeItem(at: destination)
                } else {
                    appendLog("Received \(name) → Downloads ✓")
                    if self.expectingPickedPhotos {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: destination)
                appendLog("Receive of \(name) failed")
                if pull { completePull(nil) }
            }
        }

        func loop() {
            transferConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                Task { @MainActor in
                    if let data, !data.isEmpty {
                        if let decryptor {
                            // Decrypt framed records; a nil result means corrupt/forged data.
                            guard let plain = decryptor.feed(data) else {
                                self.appendLog("Secure transfer of \(name) failed (bad data)")
                                finish(success: false)
                                return
                            }
                            if !plain.isEmpty {
                                handle.write(plain)
                                received += plain.count
                            }
                        } else {
                            handle.write(data)
                            received += data.count
                        }
                        self.transferStatus = "Receiving \(name)… \(Self.percent(received, of: size))"
                    }
                    if received >= size {
                        finish(success: true)
                    } else if isComplete || error != nil {
                        finish(success: received >= size)
                    } else {
                        loop()
                    }
                }
            }
        }

        transferConnection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    loop()
                case .failed, .waiting:
                    finish(success: false)
                default:
                    break
                }
            }
        }
        transferConnection.start(queue: .main)
    }

    // MARK: - Pull latest photo (drag-out from the mirror window)

    private var pullCompletion: ((URL?) -> Void)?

    /// Ask the phone for its most recent photo/screenshot. `completion` gets a
    /// local temp-file URL (or nil on failure/timeout). One pull at a time.
    // MARK: - File browser (Mac ↔ phone storage)

    func browsePhoneFiles() {
        guard isPaired else { return }
        fileBrowsing = true
        fsEntries = []
        send(Packet(type: "fs.list", body: ["path": ""])) // "" = storage root on the phone
        appendLog("Opening phone file browser…")
    }

    func fsNavigate(to path: String) {
        guard isPaired else { return }
        send(Packet(type: "fs.list", body: ["path": path]))
    }

    func fsDownload(name: String) {
        guard isPaired, !fsPath.isEmpty else { return }
        expectingPickedPhotos = true // reveal in Finder on arrival
        send(Packet(type: "fs.pull", body: ["path": fsPath + "/" + name]))
        appendLog("Downloading \(name)…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.expectingPickedPhotos = false
        }
    }

    /// Push Mac files into the folder currently open in the browser.
    func fsPush(urls: [URL]) {
        guard isPaired, !fsPath.isEmpty else { return }
        for url in urls { sendFile(url: url, toDir: fsPath) }
        // Refresh the listing shortly after so the pushed files appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.fsNavigate(to: self.fsPath)
        }
    }

    func closeFileBrowser() {
        fileBrowsing = false
        fsEntries = []
        fsPath = ""
    }

    // MARK: - Gallery browser

    func browsePhoneGallery() {
        guard isPaired else { return }
        galleryThumbs = []
        galleryHasMore = false
        galleryLoading = true
        send(Packet(type: "gallery.request", body: ["offset": 0]))
        appendLog("Loading phone gallery…")
    }

    func loadMoreGallery() {
        guard isPaired, galleryHasMore, !galleryLoading else { return }
        galleryLoading = true
        send(Packet(type: "gallery.request", body: ["offset": galleryThumbs.count]))
    }

    /// Tap a thumbnail → pull the full-resolution image to Downloads + reveal.
    func pullGalleryImage(id: Int) {
        pullGalleryImages(ids: [id])
    }

    func pullGalleryImages(ids: [Int]) {
        guard isPaired, !ids.isEmpty else { return }
        expectingPickedPhotos = true
        for id in ids { send(Packet(type: "gallery.pull", body: ["id": id])) }
        appendLog("Downloading \(ids.count) photo(s)…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.expectingPickedPhotos = false
        }
    }

    private func receiveGalleryThumbs(host: NWEndpoint.Host, port: UInt16, items: [(Int, String)], enc: Bool = false) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { galleryLoading = false; return }
        let conn = NWConnection(host: host, port: nwPort, using: .tcp)
        let decryptor = enc ? FramedDecryptor(crypto) : nil
        var buffer = Data()
        var index = 0

        func drain() {
            // Each thumbnail is [4-byte big-endian length][JPEG bytes].
            while index < items.count, buffer.count >= 4 {
                let len = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                // A bogus length (negative or absurd) means the framing is lost and
                // the buffer would grow without bound — abort rather than OOM.
                guard len >= 0, len <= 20_000_000 else {
                    galleryLoading = false
                    index = items.count
                    conn.cancel()
                    conn.stateUpdateHandler = nil
                    return
                }
                guard buffer.count >= 4 + len else { break }
                let jpeg = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + len))
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + len))
                let (id, name) = items[index]
                index += 1
                if len > 0, let image = NSImage(data: jpeg) {
                    galleryThumbs.append(GalleryThumb(id: id, name: name, image: image))
                }
            }
            if index >= items.count {
                galleryLoading = false
                conn.cancel()
            }
        }

        func loop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { data, _, isComplete, error in
                Task { @MainActor in
                    if let data, !data.isEmpty {
                        if let decryptor {
                            guard let plain = decryptor.feed(data) else {
                                self.galleryLoading = false
                                conn.cancel()
                                return
                            }
                            buffer.append(plain)
                        } else {
                            buffer.append(data)
                        }
                        drain()
                    }
                    if index >= items.count { return }
                    if isComplete || error != nil {
                        self.galleryLoading = false
                        conn.cancel()
                    } else {
                        loop()
                    }
                }
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: loop()
                case .failed, .waiting:
                    self?.galleryLoading = false
                    conn.cancel()
                    conn.stateUpdateHandler = nil
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    /// Ask the phone to open its photo picker; chosen photos arrive as normal
    /// transfers into Downloads and are revealed in Finder.
    func pullPhotosFromPhone() {
        guard isPaired else { return }
        expectingPickedPhotos = true
        send(Packet(type: "pull.request", body: ["kind": "pick"]))
        appendLog("Opening photo picker on the phone — choose photos there")
        // Stop revealing in Finder a minute after the request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.expectingPickedPhotos = false
        }
    }

    private var expectingPickedPhotos = false

    func pullLatestImage(_ completion: @escaping (URL?) -> Void) {
        guard isPaired else { completion(nil); return }
        guard pullCompletion == nil else { completion(nil); return }
        pullCompletion = completion
        send(Packet(type: "pull.request", body: ["kind": "latest_image"]))
        appendLog("Pulling latest photo from phone…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.pullCompletion != nil else { return }
            self.appendLog("Pull timed out")
            self.completePull(nil)
        }
    }

    private func completePull(_ url: URL?) {
        guard let completion = pullCompletion else { return }
        pullCompletion = nil
        completion(url)
    }

    // MARK: - Plumbing

    private func send(_ packet: Packet) {
        guard let connection, handshakeDone,
              let json = packet.jsonData(), let sealed = crypto.seal(json) else { return }
        connection.send(content: Data((sealed + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func dropConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        resetSessionState()
        statusText = "Advertising as “\(deviceName)”"
    }

    private func resetSessionState() {
        connectedDeviceName = nil
        pendingPairCode = nil
        isPaired = false
        transferStatus = nil
        universalControl.exitIfActive() // never leave the Mac's input trapped
        micReceiver.stop()
        audioSender?.stop()
        audioSender = nil
        speakerStreaming = false
        screenViewer.stop()
        screenViewing = false
        macScreenSender?.stop()
        macScreenSender = nil
        mirroringToPhone = false
        completePull(nil)
        statusBar.hide()
        phoneTabURL = nil
        phoneTabTitle = ""
        lastSentTabURL = nil
        nowPlaying = nil
        phoneBattery = nil
        phoneCharging = false
        lowBatteryAlerted = false
        fullBatteryAlerted = false
        menuBar?.updateBattery(level: nil, charging: false)
        callState = "idle"
        callerDisplay = ""
        callMuted = false
        callSpeaker = false
        Notifier.shared.dismissCall()
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty ? "file" : cleaned
    }

    private static func uniqueDestination(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var counter = 1
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    private static func percent(_ done: Int, of total: Int) -> String {
        guard total > 0 else { return "" }
        return "\(min(100, done * 100 / total))%"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
