import AppKit
import Foundation
import Network

@MainActor
final class ServerManager: ObservableObject {
    @Published var statusText = "Starting…"
    @Published var port: UInt16?
    @Published var connectedDeviceName: String?
    @Published var pendingPairCode: String?
    @Published var isPaired = false
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

    private var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    func start() {
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
            let listener = try NWListener(using: .tcp)
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
        appendLog("Incoming connection from \(newConnection.endpoint)")

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            Task { @MainActor in
                guard let self, let newConnection, self.connection === newConnection else { return }
                switch state {
                case .ready:
                    self.statusText = "Phone connected — waiting for pairing"
                    self.send(Packet(type: "identity", body: ["name": self.deviceName, "device": "mac"]))
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
            if let packet = Packet.decode(line) {
                handle(packet)
            }
        }
    }

    private func handle(_ packet: Packet) {
        switch packet.type {
        case "identity":
            connectedDeviceName = packet.body["name"] as? String ?? "Android device"
            appendLog("Identified: \(connectedDeviceName!)")

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
            break // keep-alive traffic, nothing to do

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

        case "audio.start":
            guard isPaired,
                  packet.body["direction"] as? String == "mic",
                  let port = packet.body["port"] as? Int,
                  let host = remoteHost()
            else { return }
            let sampleRate = packet.body["sampleRate"] as? Double ?? 16000
            let channels = packet.body["channels"] as? Int ?? 1
            micReceiver.start(host: host, port: UInt16(port), sampleRate: sampleRate, channels: channels)

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
            screenViewer.start(host: host, port: UInt16(port), width: width, height: height)
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
            receiveGalleryThumbs(host: host, port: UInt16(port), items: parsed)

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
            receiveFile(name: name, size: size, host: host, port: UInt16(port), pull: isPull)

        default:
            appendLog("Unknown packet: \(packet.type)")
        }
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

    func requestPhoneScreen() {
        guard isPaired else { return }
        send(Packet(type: "screen.request"))
        appendLog("Asked phone to share its screen — accept on the phone")
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
        sender.start { [weak self] width, height, port in
            guard let self else { return }
            self.send(Packet(type: "macscreen.start", body: ["width": width, "height": height, "port": port]))
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
        sender.start { [weak self] port in
            guard let self else { return }
            self.send(Packet(type: "audio.start", body: [
                "direction": "speaker",
                "sampleRate": SystemAudioSender.sampleRate,
                "channels": SystemAudioSender.channels,
                "port": port,
            ]))
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

    func sendFile(url: URL, toDir dir: String? = nil) {
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

        do {
            let fileListener = try NWListener(using: .tcp)
            fileListener.newConnectionHandler = { [weak self] transferConnection in
                transferConnection.start(queue: .main)
                Task { @MainActor in
                    self?.stream(handle: handle, name: name, size: size, over: transferConnection, listener: fileListener)
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

    private func stream(handle: FileHandle, name: String, size: Int, over transferConnection: NWConnection, listener fileListener: NWListener) {
        var sent = 0

        func sendNextChunk() {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty {
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
                    sent += chunk.count
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

    private func receiveFile(name: String, size: Int, host: NWEndpoint.Host, port: UInt16, pull: Bool = false) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        // Pulled files (drag-out) go to a temp dir and are handed to the drag; normal
        // transfers land in Downloads.
        let directory = pull
            ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Self.uniqueDestination(in: directory, name: Self.sanitize(name))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            appendLog("Cannot write to \(destination.path)")
            if pull { completePull(nil) }
            return
        }

        if !pull {
            transferStatus = "Receiving \(name)…"
            appendLog("Receiving \(name) (\(Self.formatBytes(size)))")
        }

        let transferConnection = NWConnection(host: host, port: nwPort, using: .tcp)
        var received = 0

        func finish(success: Bool) {
            try? handle.close()
            transferConnection.cancel()
            transferStatus = nil
            if success {
                if pull {
                    appendLog("Pulled \(name) from phone")
                    completePull(destination)
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
                        handle.write(data)
                        received += data.count
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
        guard isPaired else { return }
        expectingPickedPhotos = true
        send(Packet(type: "gallery.pull", body: ["id": id]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.expectingPickedPhotos = false
        }
    }

    private func receiveGalleryThumbs(host: NWEndpoint.Host, port: UInt16, items: [(Int, String)]) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { galleryLoading = false; return }
        let conn = NWConnection(host: host, port: nwPort, using: .tcp)
        var buffer = Data()
        var index = 0

        func drain() {
            // Each thumbnail is [4-byte big-endian length][JPEG bytes].
            while index < items.count, buffer.count >= 4 {
                let len = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
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
                    if let data, !data.isEmpty { buffer.append(data); drain() }
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

        conn.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: loop()
                case .failed, .waiting: self.galleryLoading = false
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
        guard let connection, let data = packet.encode() else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
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
