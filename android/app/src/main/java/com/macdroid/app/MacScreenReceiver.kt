package com.macdroid.app

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Connects to the Mac's screen side channel, decodes the H.264 Annex-B stream
 * with MediaCodec, and renders onto the given Surface (a full-screen SurfaceView
 * in MacScreenActivity).
 */
class MacScreenReceiver(
    private val scope: CoroutineScope,
    private val host: String,
    private val port: Int,
    private val width: Int,
    private val height: Int,
    private val surface: Surface,
    private val onLog: (String) -> Unit,
    private val onStopped: () -> Unit,
) {
    @Volatile
    private var running = false
    private var job: Job? = null
    private var socket: Socket? = null

    fun start() {
        if (running) return
        running = true
        job = scope.launch(Dispatchers.IO) {
            var codec: MediaCodec? = null
            try {
                val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
                codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                codec.configure(format, surface, null, 0)
                codec.start()

                Socket().use { s ->
                    socket = s
                    s.connect(InetSocketAddress(host, port), 10000)
                    s.tcpNoDelay = true
                    onLog("Receiving Mac screen")
                    val input = s.getInputStream()
                    val buffer = ByteArray(256 * 1024)
                    val pending = ArrayDeque<Byte>() // rolling byte buffer for NAL splitting
                    var acc = ByteArray(0)

                    val info = MediaCodec.BufferInfo()
                    while (running) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        acc += buffer.copyOf(n)

                        // Emit complete NAL units (split on 00 00 00 01 / 00 00 01).
                        var start = findStartCode(acc, 0)
                        if (start < 0) continue
                        var next = findStartCode(acc, start + 3)
                        while (next >= 0) {
                            feed(codec, acc.copyOfRange(start, next), info)
                            start = next
                            next = findStartCode(acc, start + 3)
                        }
                        acc = acc.copyOfRange(start, acc.size) // keep the trailing partial NAL

                        drainDecoder(codec, info)
                    }
                }
            } catch (e: Exception) {
                if (running) onLog("Mac screen ended: ${e.message}")
            } finally {
                try {
                    codec?.stop(); codec?.release()
                } catch (_: Exception) {
                }
                if (running) {
                    running = false
                    onStopped()
                }
            }
        }
    }

    fun stop() {
        running = false
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        job?.cancel()
        job = null
    }

    private fun feed(codec: MediaCodec, nal: ByteArray, info: MediaCodec.BufferInfo) {
        val index = codec.dequeueInputBuffer(10_000)
        if (index < 0) return
        val buf = codec.getInputBuffer(index) ?: return
        buf.clear()
        buf.put(nal)
        codec.queueInputBuffer(index, 0, nal.size, System.nanoTime() / 1000, 0)
    }

    private fun drainDecoder(codec: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val out = codec.dequeueOutputBuffer(info, 0)
            if (out < 0) break
            codec.releaseOutputBuffer(out, true) // render to the surface
        }
    }

    /** Index of the next Annex-B start code at or after [from], or -1. */
    private fun findStartCode(data: ByteArray, from: Int): Int {
        var i = from
        while (i + 3 <= data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (data[i + 2] == 1.toByte()) return i
                if (i + 4 <= data.size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) return i
            }
            i++
        }
        return -1
    }
}
