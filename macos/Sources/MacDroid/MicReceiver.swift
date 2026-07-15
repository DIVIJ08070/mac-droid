import AVFoundation
import Foundation
import Network

/// Receives the phone's microphone as raw PCM16 over TCP and plays it on a
/// selectable output device (pick a virtual device like BlackHole to expose
/// the phone as a microphone to other Mac apps).
@MainActor
final class MicReceiver: ObservableObject {
    @Published var isActive = false
    @Published var level: Float = 0 // smoothed output level 0…1, for the UI meter
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedDeviceID: AudioDeviceID = 0 // 0 = system default

    var onLog: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerAttached = false
    private var connection: NWConnection?
    private var format: AVAudioFormat?
    private var leftover = Data()
    private var channels = 1
    private var decryptor: FramedDecryptor?

    func refreshDevices() {
        outputDevices = AudioDevices.outputDevices()
    }

    func start(host: NWEndpoint.Host, port: UInt16, sampleRate: Double, channels: Int, cipher: CryptoBox? = nil) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        else { return }

        self.format = format
        self.channels = channels
        self.decryptor = cipher.map { FramedDecryptor($0) }
        refreshDevices()

        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        if selectedDeviceID != 0, let unit = engine.outputNode.audioUnit {
            var deviceID = selectedDeviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        do {
            try engine.start()
        } catch {
            onLog?("Mic playback failed to start: \(error.localizedDescription)")
            return
        }
        player.play()

        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for frame in 0..<Int(buffer.frameLength) { sum += data[frame] * data[frame] }
            let rms = min(sqrt(sum / Float(buffer.frameLength)) * 3, 1)
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.level = self.level * 0.6 + rms * 0.4
            }
        }

        let conn = NWConnection(host: host, port: nwPort, using: .tcp)
        connection = conn
        leftover = Data()
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.isActive = true
                    self.onLog?("Phone microphone connected")
                    self.receiveLoop(conn)
                case .failed(let error), .waiting(let error):
                    // .waiting means unreachable (e.g. connection refused) — on a LAN
                    // dial-back there is nothing to wait for, so treat it as failure.
                    self.onLog?("Couldn't reach the phone's mic stream (\(error.localizedDescription)) — are both devices still on the same network (Wi-Fi or hotspot)?")
                    self.stop()
                case .cancelled:
                    self.stop()
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    func stop() {
        guard connection != nil || isActive else { return }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        engine.mainMixerNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.reset()
        level = 0
        if isActive {
            isActive = false
            onLog?("Phone microphone stopped")
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    if let decryptor = self.decryptor {
                        guard let plain = decryptor.feed(data) else { self.stop(); return }
                        if !plain.isEmpty { self.playChunk(plain) }
                    } else {
                        self.playChunk(data)
                    }
                }
                if isComplete || error != nil {
                    self.stop()
                } else {
                    self.receiveLoop(conn)
                }
            }
        }
    }

    private func playChunk(_ data: Data) {
        guard let format else { return }
        leftover.append(data)
        let bytesPerFrame = 2 * channels
        let frameCount = leftover.count / bytesPerFrame
        guard frameCount > 0 else { return }
        let usableBytes = frameCount * bytesPerFrame
        let chunk = leftover.prefix(usableBytes)
        leftover.removeFirst(usableBytes)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for channel in 0..<channels {
                guard let channelData = buffer.floatChannelData?[channel] else { continue }
                for frame in 0..<frameCount {
                    channelData[frame] = Float(samples[frame * channels + channel]) / 32768.0
                }
            }
        }
        player.scheduleBuffer(buffer)
    }
}
