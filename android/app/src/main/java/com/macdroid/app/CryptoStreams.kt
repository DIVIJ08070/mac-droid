package com.macdroid.app

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * Transparent AES-256-GCM framing for side-channel byte transfers (files, screen
 * video, audio, gallery). Both wrappers present the SAME plaintext byte stream as
 * a raw socket, so every channel's existing read/write logic works unchanged —
 * only used when both peers negotiated `enc`.
 *
 * Wire format: repeated `[4-byte big-endian length N][N bytes: nonce‖ciphertext‖tag]`.
 * The concatenation of all decrypted records equals the original plaintext stream.
 */

private const val MAX_RECORD = 16 * 1024 * 1024 // guard against corrupt lengths

/** Wraps an OutputStream, sealing each write() into one length-prefixed record. */
class EncOutputStream(
    private val raw: OutputStream,
    private val crypto: CryptoBox,
) : OutputStream() {

    override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

    override fun write(b: ByteArray, off: Int, len: Int) {
        if (len <= 0) return
        val sealed = crypto.sealRaw(b, off, len)
            ?: throw IOException("side-channel encrypt failed")
        val header = ByteArray(4)
        header[0] = (sealed.size ushr 24).toByte()
        header[1] = (sealed.size ushr 16).toByte()
        header[2] = (sealed.size ushr 8).toByte()
        header[3] = sealed.size.toByte()
        raw.write(header)
        raw.write(sealed)
    }

    override fun flush() = raw.flush()
    override fun close() = raw.close()
}

/** Wraps an InputStream, decrypting records back into the plaintext stream. */
class EncInputStream(
    private val raw: InputStream,
    private val crypto: CryptoBox,
) : InputStream() {

    private var plain: ByteArray = ByteArray(0)
    private var pos = 0

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) == -1) -1 else one[0].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len <= 0) return 0
        if (pos >= plain.size && !fill()) return -1 // clean EOF at a record boundary
        val n = minOf(len, plain.size - pos)
        System.arraycopy(plain, pos, b, off, n)
        pos += n
        return n
    }

    /** Read + decrypt the next record into `plain`. False on clean EOF. */
    private fun fill(): Boolean {
        val header = ByteArray(4)
        if (!readFully(header, allowEofAtStart = true)) return false
        val size = ((header[0].toInt() and 0xFF) shl 24) or
            ((header[1].toInt() and 0xFF) shl 16) or
            ((header[2].toInt() and 0xFF) shl 8) or
            (header[3].toInt() and 0xFF)
        if (size <= 0 || size > MAX_RECORD) throw IOException("bad side-channel record length $size")
        val sealed = ByteArray(size)
        if (!readFully(sealed, allowEofAtStart = false)) throw IOException("truncated side-channel record")
        plain = crypto.openRaw(sealed) ?: throw IOException("side-channel decrypt failed")
        pos = 0
        return true
    }

    /** Fill `buf` completely. Returns false only on EOF before the first byte
     *  (and only when allowEofAtStart) — a mid-buffer EOF is a truncation error. */
    private fun readFully(buf: ByteArray, allowEofAtStart: Boolean): Boolean {
        var read = 0
        while (read < buf.size) {
            val n = raw.read(buf, read, buf.size - read)
            if (n < 0) {
                if (read == 0 && allowEofAtStart) return false
                throw IOException("unexpected EOF in side-channel record")
            }
            read += n
        }
        return true
    }

    override fun close() = raw.close()
}
