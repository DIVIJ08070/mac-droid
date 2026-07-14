package com.macdroid.app

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * Streams the phone's microphone to the Mac as raw PCM16.
 * The phone opens the listener; the Mac pulls (same model as file transfer).
 */
class MicStreamer(
    private val scope: CoroutineScope,
    private val onOffer: (sampleRate: Int, channels: Int, port: Int) -> Unit,
    private val onLog: (String) -> Unit,
    private val onStopped: () -> Unit,
) {
    @Volatile
    private var running = false
    private var job: Job? = null
    private var server: ServerSocket? = null

    val isRunning get() = running

    @SuppressLint("MissingPermission") // caller checks RECORD_AUDIO before start()
    fun start() {
        if (running) return
        running = true

        job = scope.launch(Dispatchers.IO) {
            var record: AudioRecord? = null
            try {
                record = createRecorder()
                if (record == null) {
                    onLog("Microphone failed to initialize — is another app using it?")
                    return@launch
                }

                ServerSocket(0).use { serverSocket ->
                    server = serverSocket
                    serverSocket.soTimeout = 30000
                    onOffer(SAMPLE_RATE, 1, serverSocket.localPort)
                    onLog("Mic stream ready — waiting for Mac")

                    serverSocket.accept().use { client ->
                        onLog("Mic streaming to Mac")
                        client.tcpNoDelay = true
                        val out = client.getOutputStream()
                        val buffer = ByteArray(3200) // 100 ms at 16 kHz mono PCM16
                        record.startRecording()
                        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                            onLog("Mic blocked by the system (recording didn't start)")
                            return@use
                        }
                        while (running) {
                            val n = record.read(buffer, 0, buffer.size)
                            if (n <= 0) {
                                onLog("Mic read stopped (code $n)")
                                break
                            }
                            out.write(buffer, 0, n)
                        }
                    }
                }
            } catch (e: java.net.SocketTimeoutException) {
                if (running) onLog("The Mac never connected to the mic stream — are both devices still on the same network (Wi-Fi or hotspot)? Check the Mac's Activity log and try again.")
            } catch (e: Exception) {
                if (running) onLog("Mic stream ended: ${e.message}")
            } finally {
                try {
                    record?.stop()
                } catch (_: Exception) {
                }
                record?.release()
                server = null
                if (running) {
                    running = false
                    onStopped()
                }
            }
        }
    }

    /** Some devices reject VOICE_COMMUNICATION; fall back through sources until one initializes. */
    @SuppressLint("MissingPermission")
    private fun createRecorder(): AudioRecord? {
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuffer <= 0) return null
        val sources = intArrayOf(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            MediaRecorder.AudioSource.MIC,
            MediaRecorder.AudioSource.DEFAULT,
        )
        for (source in sources) {
            try {
                val candidate = AudioRecord(
                    source, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, minBuffer * 4
                )
                if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                    android.util.Log.d("MacDroid", "AudioRecord initialized with source $source")
                    return candidate
                }
                candidate.release()
            } catch (e: Exception) {
                android.util.Log.w("MacDroid", "AudioRecord source $source failed: ${e.message}")
            }
        }
        return null
    }

    fun stop() {
        running = false
        try {
            server?.close()
        } catch (_: Exception) {
        }
        job?.cancel()
        job = null
    }

    companion object {
        const val SAMPLE_RATE = 16000
    }
}

/**
 * Plays the Mac's system audio (raw PCM16 pulled from a side channel) through
 * the phone's current audio route — including a Bluetooth device paired to the phone.
 */
class SpeakerPlayer(
    private val scope: CoroutineScope,
    private val onLog: (String) -> Unit,
    private val onStopped: () -> Unit,
) {
    @Volatile
    private var running = false
    private var job: Job? = null
    private var socket: Socket? = null

    val isRunning get() = running

    fun start(host: String, port: Int, sampleRate: Int, channels: Int) {
        stop()
        running = true

        job = scope.launch(Dispatchers.IO) {
            var track: AudioTrack? = null
            try {
                val channelMask =
                    if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
                val minBuffer = AudioTrack.getMinBufferSize(
                    sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT
                )
                track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelMask)
                            .build()
                    )
                    .setBufferSizeInBytes(maxOf(minBuffer * 2, sampleRate * channels / 2)) // ≥250 ms
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                track.play()

                Socket().use { s ->
                    socket = s
                    s.connect(InetSocketAddress(host, port), 10000)
                    onLog("Playing Mac audio on this phone")
                    val input = s.getInputStream()
                    val buffer = ByteArray(19200) // 50 ms at 48 kHz stereo PCM16
                    while (running) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        track.write(buffer, 0, n)
                    }
                }
            } catch (e: Exception) {
                if (running) onLog("Mac audio ended: ${e.message}")
            } finally {
                try {
                    track?.stop()
                } catch (_: Exception) {
                }
                track?.release()
                socket = null
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
}
