import CryptoKit
import Foundation

/// Ephemeral ECDH (P-256) key agreement + AES-256-GCM packet encryption.
/// Each connection derives a fresh shared key, so all traffic — including the
/// pairing-token exchange — is encrypted and forward-secret.
final class CryptoBox {
    private let priv = P256.KeyAgreement.PrivateKey()
    private var key: SymmetricKey?

    var isReady: Bool { key != nil }

    /// Our public key as base64 (X9.63 uncompressed point) to send to the peer.
    var publicKeyBase64: String {
        priv.publicKey.x963Representation.base64EncodedString()
    }

    /// Derive the shared AES key from the peer's base64 public key.
    @discardableResult
    func deriveKey(peerBase64: String) -> Bool {
        guard
            let data = Data(base64Encoded: peerBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
            let peer = try? P256.KeyAgreement.PublicKey(x963Representation: data),
            let secret = try? priv.sharedSecretFromKeyAgreement(with: peer)
        else { return false }
        key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("MacDroidSalt".utf8),
            sharedInfo: Data("macdroid".utf8),
            outputByteCount: 32
        )
        return true
    }

    /// Encrypt → base64 (nonce ‖ ciphertext ‖ tag).
    func seal(_ plaintext: Data) -> String? {
        guard let key, let box = try? AES.GCM.seal(plaintext, using: key), let combined = box.combined
        else { return nil }
        return combined.base64EncodedString()
    }

    /// base64 (nonce ‖ ciphertext ‖ tag) → decrypt.
    func open(_ base64: String) -> Data? {
        guard
            let key,
            let combined = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
            let box = try? AES.GCM.SealedBox(combined: combined),
            let plaintext = try? AES.GCM.open(box, using: key)
        else { return nil }
        return plaintext
    }

    // MARK: - Raw (binary) sealing for side channels
    //
    // Same key and AES-256-GCM construction as the control channel, but returns
    // raw bytes (nonce ‖ ciphertext ‖ tag) instead of base64 — used to frame
    // file/screen/audio/gallery side-channel transfers without base64 bloat.

    /// Encrypt raw bytes → Data(nonce ‖ ciphertext ‖ tag), or nil if no key.
    func sealRaw(_ plaintext: Data) -> Data? {
        guard let key, let box = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return box.combined
    }

    /// Data(nonce ‖ ciphertext ‖ tag) → plaintext, or nil on failure/no key.
    func openRaw(_ data: Data) -> Data? {
        guard let key,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(box, using: key)
        else { return nil }
        return plaintext
    }
}
