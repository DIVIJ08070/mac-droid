package com.macdroid.app

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.net.ServerSocket

/**
 * Captures the phone screen with MediaProjection, encodes H.264 with the
 * hardware encoder, and serves the raw Annex-B stream on a side channel
 * (same pull model as files/audio: phone listens, Mac connects and reads).
 */
class ScreenStreamer(
    private val context: Context,
    private val scope: CoroutineScope,
    private val cipher: CryptoBox?, // non-null → AES-GCM encrypt the H.264 stream
    private val onOffer: (width: Int, height: Int, port: Int) -> Unit,
    private val onLog: (String) -> Unit,
    private val onStopped: () -> Unit,
) {
    @Volatile
    private var running = false
    private var job: Job? = null
    private var server: ServerSocket? = null
    private var codec: MediaCodec? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var projection: MediaProjection? = null

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            stop() // user revoked from the system status bar
        }
    }

    val isRunning get() = running

    fun start(mediaProjection: MediaProjection) {
        if (running) return
        running = true
        projection = mediaProjection
        mediaProjection.registerCallback(projectionCallback, Handler(Looper.getMainLooper()))

        job = scope.launch(Dispatchers.IO) {
            try {
                val metrics = DisplayMetrics()
                @Suppress("DEPRECATION")
                (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                    .defaultDisplay.getRealMetrics(metrics)

                // Scale down to ≤720 px on the short side, even dimensions (encoder requirement).
                val scale = minOf(1f, 720f / minOf(metrics.widthPixels, metrics.heightPixels))
                val width = (metrics.widthPixels * scale).toInt() and 0xFFFE
                val height = (metrics.heightPixels * scale).toInt() and 0xFFFE

                val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                    setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                    )
                    setInteger(MediaFormat.KEY_BIT_RATE, 5_000_000)
                    setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                }
                val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                val inputSurface = encoder.createInputSurface()
                encoder.start()
                codec = encoder

                virtualDisplay = mediaProjection.createVirtualDisplay(
                    "MacDroid", width, height, metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    inputSurface, null, null
                )

                ServerSocket(0).use { serverSocket ->
                    server = serverSocket
                    serverSocket.soTimeout = 15000
                    onOffer(width, height, serverSocket.localPort)
                    onLog("Screen stream ready (${width}×${height}) — waiting for Mac")

                    serverSocket.accept().use { client ->
                        client.tcpNoDelay = true
                        onLog("Screen streaming to Mac")
                        val out = if (cipher != null) EncOutputStream(client.getOutputStream(), cipher)
                                  else client.getOutputStream()
                        val info = MediaCodec.BufferInfo()
                        val chunk = ByteArray(256 * 1024)
                        while (running) {
                            val index = encoder.dequeueOutputBuffer(info, 10_000)
                            if (index >= 0) {
                                if (info.size > 0) {
                                    val buffer = encoder.getOutputBuffer(index)!!
                                    buffer.position(info.offset)
                                    var remaining = info.size
                                    while (remaining > 0) {
                                        val n = minOf(remaining, chunk.size)
                                        buffer.get(chunk, 0, n)
                                        out.write(chunk, 0, n)
                                        remaining -= n
                                    }
                                }
                                encoder.releaseOutputBuffer(index, false)
                            }
                        }
                        out.flush()
                    }
                }
            } catch (e: Exception) {
                if (running) onLog("Screen stream ended: ${e.message}")
            } finally {
                cleanup()
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
            server?.close()
        } catch (_: Exception) {
        }
        job?.cancel()
        job = null
        cleanup()
    }

    private fun cleanup() {
        try {
            virtualDisplay?.release()
        } catch (_: Exception) {
        }
        virtualDisplay = null
        try {
            codec?.stop()
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
        try {
            projection?.unregisterCallback(projectionCallback)
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null
        server = null
    }
}
