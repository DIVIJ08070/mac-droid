import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox

/// Captures the Mac's screen with ScreenCaptureKit, encodes H.264 with VideoToolbox,
/// and streams raw Annex-B to the phone (same side-channel pull model as everything else).
final class MacScreenSender: NSObject, SCStreamOutput, SCStreamDelegate {
    var onLog: (@MainActor (String) -> Void)?
    var onStopped: (@MainActor () -> Void)?

    private var stream: SCStream?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "macdroid.macscreen")
    private var width = 0
    private var height = 0
    private var frameIndex: Int64 = 0

    func start(offer: @escaping @MainActor (_ width: Int, _ height: Int, _ port: Int) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    await log("No display found")
                    return
                }
                // Scale so the long side is ≤1280 for a smooth stream.
                let scale = min(1.0, 1280.0 / Double(display.width))
                width = (Int(Double(display.width) * scale) / 2) * 2
                height = (Int(Double(display.height) * scale) / 2) * 2

                setupEncoder()

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 5
                config.showsCursor = true

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream

                let listener = try NWListener(using: .tcp)
                listener.newConnectionHandler = { [weak self] conn in
                    guard let self else { return }
                    self.connection?.cancel()
                    self.connection = conn
                    conn.start(queue: self.queue)
                    Task { await self.log("Phone connected to Mac screen") }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            Task { @MainActor in offer(self.width, self.height, Int(port)) }
                        }
                    case .failed(let error):
                        Task { await self.log("Mac screen listener failed: \(error.localizedDescription)") }
                        self.stopInternal()
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                await log("Mac screen capture failed: \(error.localizedDescription) — allow Screen Recording for your terminal in System Settings → Privacy & Security")
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
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: encoder

    private func setupEncoder() {
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session
        )
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, connection != nil, sampleBuffer.isValid,
              let session, let imageBuffer = sampleBuffer.imageBuffer else { return }
        // Only forward frames SCK marks "complete".
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue {
            return
        }

        let pts = CMTime(value: frameIndex, timescale: 30)
        frameIndex += 1
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: imageBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            self.sendEncoded(encoded)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await self.log("Mac screen capture stopped: \(error.localizedDescription)") }
        stopInternal()
        Task { @MainActor in self.onStopped?() }
    }

    // MARK: AVCC → Annex-B on the wire

    private func sendEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let connection else { return }
        var output = Data()

        let isKeyframe = !(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { ($0 as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool } ?? false)

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    output.append(contentsOf: [0, 0, 0, 1])
                    output.append(ptr, count: size)
                }
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }

        // AVCC: [4-byte big-endian length][NAL] … → replace each length with a start code.
        var offset = 0
        let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        while offset + 4 <= totalLength {
            let nalLength = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            if nalLength <= 0 || offset + nalLength > totalLength { break }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(UnsafeBufferPointer(start: bytes + offset, count: nalLength))
            offset += nalLength
        }

        if !output.isEmpty {
            connection.send(content: output, completion: .contentProcessed { _ in })
        }
    }

    private func log(_ message: String) async {
        await MainActor.run { self.onLog?(message) }
    }
}
