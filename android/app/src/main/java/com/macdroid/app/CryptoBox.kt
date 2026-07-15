package com.macdroid.app

import android.util.Base64
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Mirrors the Mac's CryptoBox: ephemeral P-256 ECDH → HKDF-SHA256 → AES-256-GCM.
 * Encrypts the whole control channel, including the pairing-token exchange.
 */
class CryptoBox {
    private val keyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(java.security.spec.ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    private var key: SecretKeySpec? = null
    private val random = SecureRandom()

    val isReady: Boolean get() = key != null

    /** Our public key as base64 (X9.63 uncompressed point: 0x04 ‖ X ‖ Y). */
    fun publicKeyBase64(): String {
        val pub = keyPair.public as ECPublicKey
        val x = pub.w.affineX.toFixed(32)
        val y = pub.w.affineY.toFixed(32)
        val raw = ByteArray(65)
        raw[0] = 0x04
        x.copyInto(raw, 1)
        y.copyInto(raw, 33)
        return Base64.encodeToString(raw, Base64.NO_WRAP)
    }

    fun deriveKey(peerBase64: String): Boolean {
        return try {
            val raw = Base64.decode(peerBase64.trim(), Base64.NO_WRAP)
            if (raw.size != 65 || raw[0].toInt() != 4) return false
            val x = BigInteger(1, raw.copyOfRange(1, 33))
            val y = BigInteger(1, raw.copyOfRange(33, 65))
            val params = (keyPair.public as ECPublicKey).params
            val peer = KeyFactory.getInstance("EC")
                .generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
            val ka = KeyAgreement.getInstance("ECDH").apply {
                init(keyPair.private)
                doPhase(peer, true)
            }
            val shared = ka.generateSecret() // 32-byte X coordinate
            val okm = hkdfSha256(shared, "MacDroidSalt".toByteArray(), "macdroid".toByteArray(), 32)
            key = SecretKeySpec(okm, "AES")
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Encrypt → base64 (nonce ‖ ciphertext ‖ tag). */
    fun seal(plaintext: ByteArray): String? {
        val k = key ?: return null
        return try {
            val nonce = ByteArray(12).also { random.nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, k, GCMParameterSpec(128, nonce))
            val ct = cipher.doFinal(plaintext)
            Base64.encodeToString(nonce + ct, Base64.NO_WRAP)
        } catch (_: Exception) {
            null
        }
    }

    /** base64 (nonce ‖ ciphertext ‖ tag) → decrypt. */
    fun open(base64: String): ByteArray? {
        val k = key ?: return null
        return try {
            val combined = Base64.decode(base64.trim(), Base64.NO_WRAP)
            if (combined.size < 12) return null
            val nonce = combined.copyOfRange(0, 12)
            val ct = combined.copyOfRange(12, combined.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, nonce))
            cipher.doFinal(ct)
        } catch (_: Exception) {
            null
        }
    }

    // ----- Raw (binary) sealing for side channels -----
    // Same key and AES-256-GCM construction as the control channel, but returns
    // raw bytes (nonce ‖ ciphertext ‖ tag) instead of base64 — used to frame
    // file/screen/audio/gallery side-channel transfers without base64 bloat.

    /** Encrypt raw bytes → (nonce ‖ ciphertext ‖ tag), or null if no key. */
    fun sealRaw(plaintext: ByteArray, offset: Int = 0, length: Int = plaintext.size): ByteArray? {
        val k = key ?: return null
        return try {
            val nonce = ByteArray(12).also { random.nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, k, GCMParameterSpec(128, nonce))
            nonce + cipher.doFinal(plaintext, offset, length)
        } catch (_: Exception) {
            null
        }
    }

    /** (nonce ‖ ciphertext ‖ tag) → plaintext, or null on failure/no key. */
    fun openRaw(data: ByteArray, offset: Int = 0, length: Int = data.size): ByteArray? {
        val k = key ?: return null
        return try {
            if (length < 12) return null
            val nonce = data.copyOfRange(offset, offset + 12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, nonce))
            cipher.doFinal(data, offset + 12, length - 12)
        } catch (_: Exception) {
            null
        }
    }

    private fun BigInteger.toFixed(size: Int): ByteArray {
        val bytes = toByteArray()
        return when {
            bytes.size == size -> bytes
            bytes.size == size + 1 && bytes[0].toInt() == 0 -> bytes.copyOfRange(1, bytes.size)
            bytes.size < size -> ByteArray(size - bytes.size) + bytes
            else -> bytes.copyOfRange(bytes.size - size, bytes.size)
        }
    }

    /** RFC 5869 HKDF-SHA256 (extract + expand), matching CryptoKit. */
    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)

        val result = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val n = minOf(t.size, length - pos)
            t.copyInto(result, pos, 0, n)
            pos += n
            counter++
        }
        return result
    }
}
