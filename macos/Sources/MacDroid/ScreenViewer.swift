import AppKit
import AVFoundation
import Foundation
import Network
import VideoToolbox

/// Receives the phone's screen as raw H.264 Annex-B over TCP, decodes it with
/// VideoToolbox, and shows the frames in a dedicated resizable window.
@MainActor
final class ScreenViewer: NSObject {
    var onLog: ((String) -> Void)?
    var onClosed: (() -> Void)?
    /// Emits a normalized (0–1) input gesture. tap: only (x,y). swipe: all four + ms.
    var onInput: ((_ action: String, _ x: Double, _ y: Double, _ x2: Double, _ y2: Double, _ ms: Int) -> Void)?
    var onKey: ((_ text: String?, _ special: String?) -> Void)?

    private var window: NSWindow?
    private var inputView: ScreenInputView?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var connection: NWConnection?
    private var formatDescription: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var buffer = Data()
    private var active = false

    func start(host: NWEndpoint.Host, port: UInt16, width: Int, height: Int) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        active = true
        openWindow(width: width, height: height)

        let conn = NWConnection(host: host, port: nwPort, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.onLog?("Phone screen connected")
                    self.receiveLoop(conn)
                case .failed, .cancelled:
                    self.stop()
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    func stop() {
        guard active || connection != nil else { return }
        active = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer = Data()
        sps = nil; pps = nil; formatDescription = nil
        if let window {
            window.delegate = nil
            window.close()
        }
        window = nil
        inputView = nil
        displayLayer = nil
        onClosed?()
    }

    // MARK: window

    private func openWindow(width: Int, height: Int) {
        let aspect = CGFloat(height) / CGFloat(max(1, width))
        let winWidth: CGFloat = 360
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: winWidth * aspect),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Phone Screen"
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        win.aspectRatio = NSSize(width: width, height: height)

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        let hostView = ScreenInputView(frame: win.contentView!.bounds)
        hostView.wantsLayer = true
        hostView.layer = layer
        hostView.autoresizingMask = [.width, .height]
        hostView.videoSize = CGSize(width: width, height: height)
        hostView.onInput = { [weak self] action, x, y, x2, y2, ms in
            self?.onInput?(action, x, y, x2, y2, ms)
        }
        hostView.onKey = { [weak self] text, special in
            self?.onKey?(text, special)
        }
        win.contentView?.addSubview(hostView)

        displayLayer = layer
        inputView = hostView
        window = win
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(hostView)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: network → decode

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainNALUnits()
                }
                if isComplete || error != nil {
                    self.stop()
                } else {
                    self.receiveLoop(conn)
                }
            }
        }
    }

    /// Split the Annex-B byte stream on 0x00000001 / 0x000001 start codes.
    private func drainNALUnits() {
        while let range = nextNALU() {
            let nalu = buffer.subdata(in: range)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if !nalu.isEmpty { handleNALU(nalu) }
        }
        // Cap buffer growth if a start code never arrives (shouldn't happen).
        if buffer.count > 4_000_000 { buffer.removeAll(keepingCapacity: true) }
    }

    /// Returns the byte range of the next complete NAL unit payload (excluding its
    /// leading start code), or nil if a full one isn't buffered yet.
    private func nextNALU() -> Range<Data.Index>? {
        let bytes = [UInt8](buffer)
        guard let first = findStartCode(bytes, from: 0) else { return nil }
        let payloadStart = first.upperBound
        guard let second = findStartCode(bytes, from: payloadStart) else { return nil }
        return (buffer.startIndex + payloadStart)..<(buffer.startIndex + second.lowerBound)
    }

    private func findStartCode(_ bytes: [UInt8], from: Int) -> Range<Int>? {
        var i = from
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { return i..<(i + 3) }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { return i..<(i + 4) }
            }
            i += 1
        }
        return nil
    }

    private func handleNALU(_ nalu: Data) {
        let type = nalu[nalu.startIndex] & 0x1F
        switch type {
        case 7: // SPS
            sps = nalu
            buildFormatIfReady()
        case 8: // PPS
            pps = nalu
            buildFormatIfReady()
        case 5, 1: // IDR / non-IDR slice
            guard formatDescription != nil else { return }
            decode(nalu, isKeyframe: type == 5)
        default:
            break
        }
    }

    private func buildFormatIfReady() {
        guard let sps, let pps, formatDescription == nil else { return }
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress!
                let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                let params: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                var desc: CMFormatDescription?
                let status = params.withUnsafeBufferPointer { paramsBuf in
                    sizes.withUnsafeBufferPointer { sizesBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: paramsBuf.baseAddress!,
                            parameterSetSizes: sizesBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }
                if status == noErr { formatDescription = desc }
            }
        }
    }

    private func decode(_ nalu: Data, isKeyframe: Bool) {
        guard let formatDescription else { return }
        // Convert Annex-B (start code) to AVCC (4-byte big-endian length prefix).
        var avcc = Data(count: 4)
        let length = UInt32(nalu.count).bigEndian
        withUnsafeBytes(of: length) { avcc.replaceSubrange(0..<4, with: $0) }
        avcc.append(nalu)

        var blockBuffer: CMBlockBuffer?
        let dataPointer = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 1)
        avcc.copyBytes(to: dataPointer.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: dataPointer, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer
        )
        guard created == noErr, let blockBuffer else { dataPointer.deallocate(); return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        displayLayer?.enqueue(sampleBuffer)
    }
}

extension ScreenViewer: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onLog?("Screen window closed")
            self.stop()
        }
    }
}

/// Hosts the video layer and converts mouse clicks/drags into normalized (0–1)
/// phone coordinates, accounting for the letterboxing of aspect-fit video.
final class ScreenInputView: NSView {
    var videoSize = CGSize(width: 1, height: 1)
    var onInput: ((_ action: String, _ x: Double, _ y: Double, _ x2: Double, _ y2: Double, _ ms: Int) -> Void)?
    /// Keyboard passthrough: (text, special). Exactly one is non-nil.
    var onKey: ((_ text: String?, _ special: String?) -> Void)?

    private var downPoint: CGPoint?
    private var downTime: TimeInterval = 0

    override var isFlipped: Bool { true } // top-left origin, matching the phone
    override var acceptsFirstResponder: Bool { true }

    /// Maps a view-space point to the video's normalized coordinates, clamped to 0–1.
    private func normalized(_ p: CGPoint) -> CGPoint? {
        let viewW = bounds.width, viewH = bounds.height
        guard viewW > 0, viewH > 0, videoSize.width > 0, videoSize.height > 0 else { return nil }
        let scale = min(viewW / videoSize.width, viewH / videoSize.height)
        let dispW = videoSize.width * scale, dispH = videoSize.height * scale
        let originX = (viewW - dispW) / 2, originY = (viewH - dispH) / 2
        let nx = (p.x - originX) / dispW
        let ny = (p.y - originY) / dispH
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return CGPoint(x: nx, y: ny)
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        downTime = event.timestamp
    }

    override func mouseUp(with event: NSEvent) {
        guard let down = downPoint, let start = normalized(down) else { downPoint = nil; return }
        let up = convert(event.locationInWindow, from: nil)
        let dragDistance = hypot(up.x - down.x, up.y - down.y)
        if dragDistance < 8 {
            onInput?("tap", start.x, start.y, 0, 0, 0)
        } else if let end = normalized(up) {
            let ms = Int(max(60, min(1500, (event.timestamp - downTime) * 1000)))
            onInput?("swipe", start.x, start.y, end.x, end.y, ms)
        }
        downPoint = nil
    }

    // Scroll wheel → vertical swipe (natural direction).
    override func scrollWheel(with event: NSEvent) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let n = normalized(center) else { return }
        let dy = Double(event.scrollingDeltaY)
        let delta = max(-0.35, min(0.35, dy / 400))
        onInput?("swipe", n.x, n.y, n.x, n.y + delta, 120)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onKey?(nil, "backspace")           // delete / forward-delete
        case 36, 76:  onKey?(nil, "enter")               // return / keypad enter
        case 49:      onKey?(nil, "space")
        case 53:      onKey?(nil, "back")                // esc → Android Back
        default:
            if let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
                onKey?(chars, nil)
            }
        }
    }
}
