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

    private var window: NSWindow?
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
        let hostView = NSView(frame: win.contentView!.bounds)
        hostView.wantsLayer = true
        hostView.layer = layer
        hostView.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(hostView)

        displayLayer = layer
        window = win
        win.makeKeyAndOrderFront(nil)
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
