import Foundation

/// Transparent AES-256-GCM framing for side-channel byte transfers (files, screen
/// video, audio, gallery). Reuses the connection's session key so encrypted side
/// channels are exactly as strong as the control channel — only used when both
/// peers negotiated `enc`.
///
/// Wire format: repeated `[4-byte big-endian length N][N bytes: nonce‖ciphertext‖tag]`.
/// The concatenation of all decrypted records equals the original plaintext stream.
enum SideChannelCrypto {
    static let maxRecord = 16 * 1024 * 1024 // guard against corrupt lengths

    /// Frame a plaintext chunk as `[4-byte BE length][sealed]`, or nil if no key.
    static func sealRecord(_ crypto: CryptoBox, _ plaintext: Data) -> Data? {
        guard let sealed = crypto.sealRaw(plaintext) else { return nil }
        var out = Data(capacity: 4 + sealed.count)
        let len = UInt32(sealed.count)
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(sealed)
        return out
    }
}

/// Accumulates raw socket bytes and yields decrypted plaintext as complete
/// records arrive. Mirrors the Android EncInputStream on the receive side.
final class FramedDecryptor {
    private let crypto: CryptoBox
    private var buffer = [UInt8]()

    init(_ crypto: CryptoBox) { self.crypto = crypto }

    /// Feed raw bytes; returns the plaintext of all newly-complete records
    /// (empty if none complete yet), or nil on a decrypt/protocol error.
    func feed(_ raw: Data) -> Data? {
        buffer.append(contentsOf: raw)
        var out = Data()
        var idx = 0
        while buffer.count - idx >= 4 {
            let len = (Int(buffer[idx]) << 24) | (Int(buffer[idx + 1]) << 16)
                | (Int(buffer[idx + 2]) << 8) | Int(buffer[idx + 3])
            if len <= 0 || len > SideChannelCrypto.maxRecord { return nil }
            if buffer.count - idx < 4 + len { break }
            let sealed = Data(buffer[(idx + 4)..<(idx + 4 + len)])
            guard let plain = crypto.openRaw(sealed) else { return nil }
            out.append(plain)
            idx += 4 + len
        }
        if idx > 0 { buffer.removeFirst(idx) }
        return out
    }
}
