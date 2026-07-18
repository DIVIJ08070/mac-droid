import CoreMedia
import Foundation
import Network
import ScreenCaptureKit

/// Captures the Mac's system audio with ScreenCaptureKit and streams it as raw
/// PCM16 to the phone, which plays it on its current audio route (e.g. the
/// Bluetooth device paired to the phone).
final class SystemAudioSender: NSObject, SCStreamOutput, SCStreamDelegate {
    static let sampleRate = 48000
    static let channels = 2

    var onLog: (@MainActor (String) -> Void)?
    var onStopped: (@MainActor () -> Void)?

    private var stream: SCStream?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var cipher: CryptoBox? // non-nil → AES-GCM encrypt the PCM stream
    private let audioQueue = DispatchQueue(label: "macdroid.audio.capture")

    /// Starts capture + listener; calls `offer` with the side-channel port once ready.
    func start(cipher: CryptoBox? = nil, offer: @escaping @MainActor (Int) -> Void) {
        self.cipher = cipher
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    await self.log("No display found for audio capture")
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Self.sampleRate
                config.channelCount = Self.channels
                // We only want audio; keep the mandatory video side as small and slow as possible.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                try await stream.startCapture()
                self.stream = stream

                let listener = try NWListener(using: .tcp)
                listener.newConnectionHandler = { [weak self] conn in
                    guard let self else { return }
                    self.connection?.cancel()
                    self.connection = conn
                    conn.start(queue: self.audioQueue)
                    Task { await self.log("Phone connected to Mac audio stream") }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            Task { @MainActor in offer(Int(port)) }
                        }
                    case .failed(let error):
                        Task { await self.log("Audio listener failed: \(error.localizedDescription)") }
                        self.stopInternal()
                    default:
                        break
                    }
                }
                listener.start(queue: audioQueue)
                self.listener = listener
            } catch {
                await self.log("System audio capture failed: \(error.localizedDescription) — if this mentions permissions, allow Screen & System Audio Recording for your terminal in System Settings → Privacy & Security")
                await MainActor.run { self.onStopped?() }
            }
        }
    }

    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let connection, sampleBuffer.isValid else { return }
        guard let pcm16 = Self.interleavedPCM16(from: sampleBuffer) else { return }
        let payload: Data
        if let cipher {
            // Drop the chunk rather than send raw PCM into an encrypted stream.
            guard let sealed = SideChannelCrypto.sealRecord(cipher, pcm16) else { return }
            payload = sealed
        } else {
            payload = pcm16
        }
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await self.log("Audio capture stopped: \(error.localizedDescription)") }
        stopInternal()
        Task { @MainActor in self.onStopped?() }
    }

    /// ScreenCaptureKit delivers float32 (usually deinterleaved) buffers; convert
    /// to interleaved little-endian Int16 for the wire.
    private static func interleavedPCM16(from sampleBuffer: CMSampleBuffer) -> Data? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        return try? sampleBuffer.withAudioBufferList { buffers, _ -> Data in
            var output = Data(count: frameCount * channels * 2)
            output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                let samples = out.bindMemory(to: Int16.self)
                if buffers.count >= channels {
                    // Deinterleaved: one buffer per channel.
                    for channel in 0..<channels {
                        guard let base = buffers[channel].mData else { continue }
                        let floats = base.assumingMemoryBound(to: Float.self)
                        // Clamp to the buffer's real length — a short channel buffer
                        // would otherwise read past the end.
                        let available = Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size
                        for frame in 0..<min(frameCount, available) {
                            samples[frame * channels + channel] = clamp(floats[frame])
                        }
                    }
                } else if let base = buffers[0].mData {
                    // Interleaved single buffer.
                    let floats = base.assumingMemoryBound(to: Float.self)
                    let available = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                    for index in 0..<min(frameCount * channels, available) {
                        samples[index] = clamp(floats[index])
                    }
                }
            }
            return output
        }
    }

    private static func clamp(_ value: Float) -> Int16 {
        Int16(max(-32768, min(32767, value * 32767)))
    }

    private func log(_ message: String) async {
        await MainActor.run { self.onLog?(message) }
    }
}
