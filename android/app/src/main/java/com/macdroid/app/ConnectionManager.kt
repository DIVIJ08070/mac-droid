package com.macdroid.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom

enum class ConnectionState { DISCONNECTED, CONNECTING, PAIRING, PAIRED }

/** Owns the TCP link to the Mac. Singleton so the service and UI share one connection. */
object ConnectionManager {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var connectionJob: Job? = null
    private var heartbeatJob: Job? = null
    private var socket: Socket? = null
    private var writer: PrintWriter? = null
    private var crypto = CryptoBox()
    @Volatile private var handshakeDone = false
    private lateinit var appContext: Context

    // Incremented on every connect/disconnect; a connection attempt that finds the
    // session id has moved on knows it was superseded and must not touch shared state.
    private var sessionId = 0

    private var currentMac: DiscoveredMac? = null
    private var usedTokenForPairing = false
    private val pendingShares = mutableListOf<Uri>()

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state

    private val _macName = MutableStateFlow<String?>(null)
    val macName: StateFlow<String?> = _macName

    private val _pairCode = MutableStateFlow<String?>(null)
    val pairCode: StateFlow<String?> = _pairCode

    private val _lastReceivedClipboard = MutableStateFlow<String?>(null)
    val lastReceivedClipboard: StateFlow<String?> = _lastReceivedClipboard

    private val _transferStatus = MutableStateFlow<String?>(null)
    val transferStatus: StateFlow<String?> = _transferStatus

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log

    private val _micStreaming = MutableStateFlow(false)
    val micStreaming: StateFlow<Boolean> = _micStreaming

    private val _speakerPlaying = MutableStateFlow(false)
    val speakerPlaying: StateFlow<Boolean> = _speakerPlaying

    /** The page currently open in the Mac's browser (url to title), for tab sync. */
    private val _macTab = MutableStateFlow<Pair<String, String>?>(null)
    val macTab: StateFlow<Pair<String, String>?> = _macTab

    private var micStreamer: MicStreamer? = null
    private var speakerPlayer: SpeakerPlayer? = null
    private var screenStreamer: ScreenStreamer? = null
    private var macScreenReceiver: MacScreenReceiver? = null
    private var pendingMacScreen: Triple<String, Int, Pair<Int, Int>>? = null
    private var macScreenSurface: android.view.Surface? = null

    private val _screenSharing = MutableStateFlow(false)
    val screenSharing: StateFlow<Boolean> = _screenSharing

    private val _mirrorNotifications = MutableStateFlow(false)
    val mirrorNotifications: StateFlow<Boolean> = _mirrorNotifications

    // Touchpad events must stay ordered, so a single consumer drains this queue.
    private val inputChannel =
        Channel<Packet>(capacity = 512, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    fun init(context: Context) {
        appContext = context.applicationContext
        createNotificationChannel()
        _mirrorNotifications.value =
            appContext.getSharedPreferences("macdroid", Context.MODE_PRIVATE)
                .getBoolean("mirrorNotifications", false)
        // A remembered Mac means the reconnect service should be running from the
        // start — it owns discovery/USB-tunnel retries. Without this it only starts
        // after the next successful pairing, so a fresh app launch never reconnects
        // on its own.
        if (hasRememberedMac()) {
            try {
                startBackgroundService()
            } catch (e: Exception) {
                android.util.Log.w("MacDroid", "Reconnect service start failed: ${e.message}")
            }
        }
        scope.launch {
            for (packet in inputChannel) {
                try {
                    writePacket(packet)
                } catch (_: Exception) {
                }
            }
        }
        // Poll the phone's active media session and push now-playing to the Mac.
        scope.launch {
            while (true) {
                try {
                    pollMedia()
                } catch (_: Exception) {
                }
                kotlinx.coroutines.delay(1500)
            }
        }
    }

    private var mediaController: android.media.session.MediaController? = null
    private var lastMediaKey = ""

    private fun pollMedia() {
        if (_state.value != ConnectionState.PAIRED) return
        if (!NotificationMirrorService.isEnabled(appContext)) return
        val msm = appContext.getSystemService(android.media.session.MediaSessionManager::class.java)
        val component = android.content.ComponentName(appContext, NotificationMirrorService::class.java)
        val controllers = msm.getActiveSessions(component)
        val controller = controllers.firstOrNull {
            it.playbackState?.state == android.media.session.PlaybackState.STATE_PLAYING
        } ?: controllers.firstOrNull()
        mediaController = controller

        if (controller == null) {
            if (lastMediaKey.isNotEmpty()) {
                lastMediaKey = ""
                scope.launch { send(Packet("media.none")) }
            }
            return
        }

        val md = controller.metadata
        val title = md?.getString(android.media.MediaMetadata.METADATA_KEY_TITLE).orEmpty()
        val artist = (md?.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST)
            ?: md?.getString(android.media.MediaMetadata.METADATA_KEY_ALBUM_ARTIST)).orEmpty()
        val playing = controller.playbackState?.state == android.media.session.PlaybackState.STATE_PLAYING
        val key = "$title|$artist|$playing"
        if (key == lastMediaKey) return
        val trackChanged = !lastMediaKey.startsWith("$title|$artist|")
        lastMediaKey = key

        val body = JSONObject()
            .put("title", title).put("artist", artist).put("playing", playing)
        if (trackChanged) {
            val art = md?.getBitmap(android.media.MediaMetadata.METADATA_KEY_ALBUM_ART)
                ?: md?.getBitmap(android.media.MediaMetadata.METADATA_KEY_ART)
                ?: md?.getBitmap(android.media.MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            if (art != null) {
                val side = 240
                val scaled = android.graphics.Bitmap.createScaledBitmap(art, side, side, true)
                val bos = java.io.ByteArrayOutputStream()
                scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, bos)
                body.put("art", android.util.Base64.encodeToString(bos.toByteArray(), android.util.Base64.NO_WRAP))
            }
        }
        scope.launch { send(Packet("media.now", body)) }
    }

    private fun handleMediaCommand(action: String) {
        val tc = mediaController?.transportControls ?: return
        val playing = mediaController?.playbackState?.state == android.media.session.PlaybackState.STATE_PLAYING
        when (action) {
            "play" -> tc.play()
            "pause" -> tc.pause()
            "playpause" -> if (playing) tc.pause() else tc.play()
            "next" -> tc.skipToNext()
            "prev" -> tc.skipToPrevious()
        }
    }

    /** Encrypt and write a packet (once the secure channel is up). */
    private fun writePacket(packet: Packet) {
        val w = writer ?: return
        if (!handshakeDone) return
        val sealed = crypto.seal(packet.encode().toByteArray()) ?: return
        w.println(sealed)
    }

    /** Low-latency touchpad events; dropped silently when not connected. */
    fun sendInput(
        action: String,
        dx: Float = 0f,
        dy: Float = 0f,
        button: String? = null,
        gesture: String? = null,
    ) {
        if (_state.value != ConnectionState.PAIRED) return
        val body = JSONObject().put("a", action)
        if (dx != 0f) body.put("dx", dx.toDouble())
        if (dy != 0f) body.put("dy", dy.toDouble())
        button?.let { body.put("b", it) }
        gesture?.let {
            body.put("g", it)
            appendLog("Gesture: $it") // infrequent — safe to log for diagnostics
        }
        inputChannel.trySend(Packet("input", body))
    }

    // MARK: momentum scrolling

    private var flingJob: Job? = null

    /** Keep scrolling with decay after a two-finger fling, like a real trackpad. */
    fun startScrollFling(vxPxPerMs: Float, vyPxPerMs: Float) {
        cancelScrollFling()
        flingJob = scope.launch {
            var vx = vxPxPerMs.coerceIn(-4f, 4f)
            var vy = vyPxPerMs.coerceIn(-4f, 4f)
            while (kotlin.math.abs(vx) > 0.04f || kotlin.math.abs(vy) > 0.04f) {
                sendInput("sc", vx * 16, vy * 16)
                vx *= 0.93f
                vy *= 0.93f
                kotlinx.coroutines.delay(16)
            }
        }
    }

    fun cancelScrollFling() {
        flingJob?.cancel()
        flingJob = null
    }

    // MARK: remembered pairing

    private val prefs
        get() = appContext.getSharedPreferences("macdroid", Context.MODE_PRIVATE)

    fun rememberedMacName(): String? = prefs.getString("pairedMacName", null)

    // MARK: optional connect-by-address (e.g. a Tailscale IP, for use away from home)

    const val DEFAULT_PORT = 52377

    fun savedManualAddress(): String? = prefs.getString("manualAddress", null)

    fun forgetManualAddress() = prefs.edit().remove("manualAddress").apply()

    /** Connect to "host" or "host:port" directly — additive; LAN discovery is untouched. */
    fun connectManual(addressInput: String) {
        val input = addressInput.trim()
        if (input.isEmpty()) return
        val host: String
        val port: Int
        val colon = input.lastIndexOf(':')
        if (colon > 0 && input.substring(colon + 1).toIntOrNull() != null) {
            host = input.substring(0, colon)
            port = input.substring(colon + 1).toInt()
        } else {
            host = input
            port = DEFAULT_PORT
        }
        prefs.edit().putString("manualAddress", input).apply()
        appendLog("Connecting by address: $host:$port")
        connect(DiscoveredMac(host, host, port))
    }

    fun hasRememberedMac(): Boolean = rememberedMacName() != null && prefs.getString("pairToken", null) != null

    fun forgetMac() {
        prefs.edit().remove("pairedMacName").remove("pairToken").apply()
        appContext.stopService(Intent(appContext, ConnectionService::class.java))
        disconnect()
        appendLog("Forgot remembered Mac")
    }

    // MARK: connection lifecycle

    @Synchronized
    fun connect(mac: DiscoveredMac) {
        // Already connected or connecting to this Mac? Don't tear down a live
        // session — this is how the reconnect service and a manual tap can race.
        if (_state.value != ConnectionState.DISCONNECTED && currentMac?.name == mac.name) {
            return
        }
        disconnect()
        val mySession = sessionId
        currentMac = mac
        _state.value = ConnectionState.CONNECTING
        _macName.value = mac.name
        appendLog("Connecting to ${mac.name} (${mac.host}:${mac.port})")

        connectionJob = scope.launch {
            var s: Socket? = null
            try {
                s = Socket()
                s.connect(InetSocketAddress(mac.host, mac.port), 5000)
                s.tcpNoDelay = true
                s.keepAlive = true

                val newCrypto = CryptoBox()
                synchronized(this@ConnectionManager) {
                    if (mySession != sessionId) {
                        s.close()
                        return@launch
                    }
                    socket = s
                    writer = PrintWriter(s.getOutputStream(), true)
                    crypto = newCrypto
                    handshakeDone = false
                }

                val reader = BufferedReader(InputStreamReader(s.getInputStream()))

                // Key exchange: send our public key, receive the Mac's, derive the AES key.
                writer!!.println(newCrypto.publicKeyBase64())
                val peerKey = reader.readLine() ?: throw java.io.IOException("no key from Mac")
                if (!newCrypto.deriveKey(peerKey)) throw java.io.IOException("key exchange failed")
                handshakeDone = true
                appendLog("Secure channel established (AES-256-GCM)")

                send(Packet("identity", JSONObject().apply {
                    put("name", "${Build.MANUFACTURER} ${Build.MODEL}")
                    put("device", "android")
                }))

                sendPairRequest(mac)
                startHeartbeat(mySession)

                while (mySession == sessionId) {
                    val line = reader.readLine() ?: break
                    val json = newCrypto.open(line) ?: continue
                    Packet.decode(String(json))?.let { handle(it) }
                }
            } catch (e: Exception) {
                if (mySession == sessionId) appendLog("Connection error: ${e.message}")
            } finally {
                cleanup(mySession, s)
            }
        }
    }

    /**
     * Periodically writes a no-op packet so a dead link (Mac app quit, Wi-Fi drop)
     * is detected within seconds instead of whenever the OS gives up on the socket.
     */
    private fun startHeartbeat(mySession: Int) {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (mySession == sessionId) {
                kotlinx.coroutines.delay(15_000)
                if (mySession != sessionId) break
                val w = writer ?: break
                writePacket(Packet("heartbeat"))
                if (w.checkError()) {
                    appendLog("Link to Mac lost")
                    try {
                        socket?.close() // unblocks the reader; cleanup follows there
                    } catch (_: Exception) {
                    }
                    break
                }
            }
        }
    }

    private fun sendPairRequest(mac: DiscoveredMac) {
        val token = prefs.getString("pairToken", null)
        // Try the stored token whenever we have one — works for LAN discovery AND
        // connect-by-address (where the "name" is an IP that won't match the saved one).
        if (token != null) {
            usedTokenForPairing = true
            _state.value = ConnectionState.PAIRING
            send(Packet("pair.request", JSONObject().put("token", token)))
            appendLog("Reconnecting with remembered pairing")
        } else {
            usedTokenForPairing = false
            val code = generatePairCode()
            _pairCode.value = code
            _state.value = ConnectionState.PAIRING
            send(Packet("pair.request", JSONObject().put("code", code)))
            appendLog("Sent pairing request, code $code")
        }
    }

    /** User-initiated disconnect: also stops the background service so it doesn't reconnect. */
    fun userDisconnect() {
        appContext.stopService(Intent(appContext, ConnectionService::class.java))
        disconnect()
    }

    @Synchronized
    fun disconnect() {
        sessionId++
        micStreamer?.stop()
        micStreamer = null
        _micStreaming.value = false
        stopSpeaker()
        stopScreenShare(notifyMac = false)
        heartbeatJob?.cancel()
        heartbeatJob = null
        connectionJob?.cancel()
        connectionJob = null
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        handshakeDone = false
        writer = null
        _pairCode.value = null
        _transferStatus.value = null
        _macTab.value = null
        if (_state.value != ConnectionState.DISCONNECTED) {
            _state.value = ConnectionState.DISCONNECTED
            appendLog("Disconnected")
        }
    }

    // MARK: actions

    fun sendClipboard() {
        val clipboardManager =
            appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboardManager.primaryClip
        val item = clip?.getItemAt(0)

        // If the clipboard holds an image (or any file URI), send the bytes so it
        // lands on the Mac's clipboard as an image — ⌘V into any Mac app.
        val uri = item?.uri
        val desc = clipboardManager.primaryClipDescription
        val isImage = uri != null && desc != null &&
            (0 until desc.mimeTypeCount).any { desc.getMimeType(it).startsWith("image/") }
        if (isImage) {
            sendClipboardImage(uri!!)
            return
        }

        val text = item?.coerceToText(appContext)?.toString()
        if (text.isNullOrEmpty()) {
            appendLog("Clipboard is empty — nothing to send")
            return
        }
        scope.launch {
            send(Packet("clipboard", JSONObject().put("content", text)))
            appendLog("Clipboard → Mac (${text.length} chars)")
        }
    }

    /** Send a copied image to the Mac's clipboard (paste with ⌘V). */
    private fun sendClipboardImage(uri: Uri) {
        scope.launch(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val resolver = appContext.contentResolver
                var name = "image"
                var size = -1L
                resolver.query(uri, null, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0) name = c.getString(ni) ?: name
                        if (si >= 0) size = c.getLong(si)
                    }
                }
                if (size < 0) { // not all providers report size — read into memory
                    val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return@launch
                    size = bytes.size.toLong()
                    java.net.ServerSocket(0).use { server ->
                        server.soTimeout = 15000
                        send(Packet("clipboard.image", JSONObject().apply {
                            put("name", name); put("size", size); put("port", server.localPort)
                        }))
                        server.accept().use { it.getOutputStream().apply { write(bytes); flush() } }
                    }
                    appendLog("Image → Mac clipboard")
                    return@launch
                }
                java.net.ServerSocket(0).use { server ->
                    server.soTimeout = 15000
                    send(Packet("clipboard.image", JSONObject().apply {
                        put("name", name); put("size", size); put("port", server.localPort)
                    }))
                    server.accept().use { client ->
                        resolver.openInputStream(uri)?.use { input ->
                            val out = client.getOutputStream(); val buf = ByteArray(65536)
                            while (true) { val n = input.read(buf); if (n < 0) break; out.write(buf, 0, n) }
                            out.flush()
                        }
                    }
                }
                appendLog("Image → Mac clipboard")
            } catch (e: Exception) {
                appendLog("Clipboard image failed: ${e.message}")
            }
        }
    }

    fun pingMac() {
        scope.launch {
            send(Packet("ping", JSONObject().put("message", "Ping from phone")))
            appendLog("Ping → Mac")
        }
    }

    fun setMirrorNotifications(enabled: Boolean) {
        _mirrorNotifications.value = enabled
        appContext.getSharedPreferences("macdroid", Context.MODE_PRIVATE)
            .edit().putBoolean("mirrorNotifications", enabled).apply()
        appendLog(if (enabled) "Notification mirroring on" else "Notification mirroring off")
    }

    fun sendNotification(app: String, title: String, text: String) {
        if (_state.value != ConnectionState.PAIRED) return
        scope.launch {
            send(Packet("notification", JSONObject().apply {
                put("app", app)
                put("title", title)
                put("text", text)
            }))
        }
    }

    fun sendCommand(action: String) {
        if (_state.value != ConnectionState.PAIRED) return
        scope.launch {
            send(Packet("command", JSONObject().put("action", action)))
            appendLog("Command → Mac: $action")
        }
    }

    /** Tab sync: tell the Mac which page is open in the phone's browser. */
    fun sendBrowse(url: String) {
        if (_state.value != ConnectionState.PAIRED) return
        scope.launch {
            send(Packet("browse", JSONObject().apply {
                put("url", url)
                put("source", "phone")
            }))
        }
    }

    fun sendUrl(url: String) {
        if (_state.value != ConnectionState.PAIRED) {
            appendLog("Not connected — link not sent")
            return
        }
        scope.launch {
            send(Packet("url", JSONObject().put("url", url)))
            appendLog("Link → Mac: $url")
        }
    }

    /** Send whatever URL is on the phone's clipboard to open on the Mac. */
    fun sendClipboardUrl() {
        val clipboardManager =
            appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val text = clipboardManager.primaryClip?.getItemAt(0)
            ?.coerceToText(appContext)?.toString()?.trim()
        if (text.isNullOrEmpty() || !(text.startsWith("http://") || text.startsWith("https://"))) {
            appendLog("Clipboard doesn't contain a link")
            return
        }
        sendUrl(text)
    }

    // MARK: microphone streaming (phone → Mac)

    fun startMic() {
        if (_state.value != ConnectionState.PAIRED || _micStreaming.value) return
        val streamer = MicStreamer(
            scope = scope,
            onOffer = { sampleRate, channels, port ->
                send(Packet("audio.start", JSONObject().apply {
                    put("direction", "mic")
                    put("sampleRate", sampleRate)
                    put("channels", channels)
                    put("port", port)
                }))
            },
            onLog = ::appendLog,
            onStopped = { _micStreaming.value = false },
        )
        micStreamer = streamer
        _micStreaming.value = true
        streamer.start()
    }

    fun stopMic() {
        if (micStreamer == null) return
        scope.launch {
            send(Packet("audio.stop", JSONObject().put("direction", "mic")))
        }
        micStreamer?.stop()
        micStreamer = null
        _micStreaming.value = false
        appendLog("Mic streaming stopped")
    }

    fun stopSpeaker() {
        speakerPlayer?.stop()
        speakerPlayer = null
        _speakerPlaying.value = false
    }

    // MARK: view Mac screen on the phone

    /** Ask the Mac to start mirroring its screen here. */
    fun requestMacScreen() {
        if (_state.value != ConnectionState.PAIRED) return
        scope.launch {
            send(Packet("macscreen.request"))
            appendLog("Asked Mac to share its screen")
        }
    }

    /** Called by MacScreenActivity once its Surface is ready. */
    fun attachMacScreenSurface(surface: android.view.Surface) {
        macScreenSurface = surface
        val pending = pendingMacScreen ?: return
        val (host, port, size) = pending
        val receiver = MacScreenReceiver(
            scope = scope,
            host = host, port = port, width = size.first, height = size.second,
            surface = surface,
            onLog = ::appendLog,
            onStopped = { },
        )
        macScreenReceiver = receiver
        receiver.start()
    }

    fun detachMacScreenSurface() {
        macScreenSurface = null
        macScreenReceiver?.stop()
        macScreenReceiver = null
    }

    fun stopMacScreen(notifyMac: Boolean = true) {
        macScreenReceiver?.stop()
        macScreenReceiver = null
        pendingMacScreen = null
        if (notifyMac) scope.launch { send(Packet("macscreen.stop")) }
    }

    // MARK: screen sharing (phone → Mac)

    /**
     * Creates the MediaProjection and starts capture. MUST be called from the
     * ConnectionService AFTER it has entered a mediaProjection-type foreground
     * service, or getMediaProjection() throws a SecurityException on Android 14+.
     */
    fun beginScreenShare(resultCode: Int, data: Intent) {
        if (_state.value != ConnectionState.PAIRED || _screenSharing.value) return
        val mpm = appContext.getSystemService(android.media.projection.MediaProjectionManager::class.java)
        val projection = try {
            mpm?.getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            appendLog("Screen capture denied by system: ${e.message}")
            null
        } ?: return

        _screenSharing.value = true
        val streamer = ScreenStreamer(
            context = appContext,
            scope = scope,
            onOffer = { width, height, port ->
                send(Packet("screen.start", JSONObject().apply {
                    put("width", width)
                    put("height", height)
                    put("port", port)
                }))
            },
            onLog = ::appendLog,
            onStopped = {
                _screenSharing.value = false
                scope.launch { send(Packet("screen.stop")) }
            },
        )
        screenStreamer = streamer
        streamer.start(projection)
    }

    fun stopScreenShare(notifyMac: Boolean = true) {
        val hadStreamer = screenStreamer != null
        screenStreamer?.stop()
        screenStreamer = null
        _screenSharing.value = false
        if (hadStreamer && notifyMac) {
            scope.launch { send(Packet("screen.stop")) }
            appendLog("Screen sharing stopped")
        }
    }

    /** Send files now if paired, otherwise queue them until pairing completes. */
    fun shareFiles(uris: List<Uri>) {
        if (uris.isEmpty()) return
        if (_state.value == ConnectionState.PAIRED) {
            uris.forEach { sendFile(it) }
        } else {
            synchronized(pendingShares) { pendingShares += uris }
            appendLog("${uris.size} file(s) queued — will send once connected")
        }
    }

    // MARK: file transfer — sending (phone → Mac)

    // MARK: file manager (browse the phone's storage from the Mac)

    private val storageRoot: String
        get() = android.os.Environment.getExternalStorageDirectory().absolutePath

    private fun hasAllFilesAccess(): Boolean =
        android.os.Build.VERSION.SDK_INT < 30 ||
            android.os.Environment.isExternalStorageManager()

    fun requestAllFilesAccess() {
        try {
            appContext.startActivity(
                Intent(
                    android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${appContext.packageName}")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
            try {
                appContext.startActivity(
                    Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun serveFsList(requestedPath: String) {
        scope.launch(kotlinx.coroutines.Dispatchers.IO) {
            val path = requestedPath.ifEmpty { storageRoot }
            if (!hasAllFilesAccess()) {
                appendLog("Grant 'All files access' on the phone to browse files")
                requestAllFilesAccess()
                send(Packet("fs.entries", JSONObject().apply {
                    put("path", path)
                    put("needsPermission", true)
                    put("entries", org.json.JSONArray())
                }))
                return@launch
            }
            try {
                val dir = java.io.File(path)
                val arr = org.json.JSONArray()
                dir.listFiles()
                    ?.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
                    ?.forEach { f ->
                        arr.put(JSONObject().apply {
                            put("name", f.name)
                            put("dir", f.isDirectory)
                            put("size", if (f.isDirectory) 0L else f.length())
                        })
                    }
                send(Packet("fs.entries", JSONObject().apply {
                    put("path", dir.absolutePath)
                    put("parent", dir.parentFile?.absolutePath ?: "")
                    put("entries", arr)
                }))
            } catch (e: Exception) {
                appendLog("Cannot list $path: ${e.message}")
            }
        }
    }

    private fun sendFileFromPath(file: java.io.File) {
        scope.launch(kotlinx.coroutines.Dispatchers.IO) {
            try {
                if (!file.exists() || !file.isFile) {
                    appendLog("File not found: ${file.name}")
                    return@launch
                }
                val size = file.length()
                java.net.ServerSocket(0).use { server ->
                    server.soTimeout = 15000
                    send(Packet("file.offer", JSONObject().apply {
                        put("name", file.name)
                        put("size", size)
                        put("port", server.localPort)
                    }))
                    appendLog("Sending ${file.name} to Mac")
                    server.accept().use { client ->
                        client.tcpNoDelay = true
                        file.inputStream().use { input ->
                            val out = client.getOutputStream()
                            val buf = ByteArray(65536)
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                            }
                            out.flush()
                        }
                    }
                }
                appendLog("Sent ${file.name} ✓")
            } catch (e: Exception) {
                appendLog("Send failed: ${e.message}")
            }
        }
    }

    /** Stream a page of gallery thumbnails to the Mac's browser, starting at [offset]. */
    private fun serveGalleryThumbnails(offset: Int) {
        scope.launch(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                val projection = arrayOf(
                    MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME
                )
                val sort = "${MediaStore.Images.Media.DATE_ADDED} DESC"
                val items = mutableListOf<Pair<Long, String>>()
                var total = 0
                appContext.contentResolver.query(collection, projection, null, null, sort)?.use { c ->
                    total = c.count
                    val idCol = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                    val nameCol = c.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                    if (c.moveToPosition(offset)) {
                        do {
                            items.add(c.getLong(idCol) to (c.getString(nameCol) ?: "photo"))
                        } while (items.size < GALLERY_PAGE_SIZE && c.moveToNext())
                    }
                }
                val hasMore = offset + items.size < total
                if (items.isEmpty()) {
                    // Still tell the Mac (so it can stop the spinner).
                    send(Packet("gallery.thumbs", JSONObject().apply {
                        put("offset", offset)
                        put("hasMore", false)
                        put("items", org.json.JSONArray())
                    }))
                    appendLog("No more gallery photos")
                    return@launch
                }

                java.net.ServerSocket(0).use { server ->
                    server.soTimeout = 20000
                    val arr = org.json.JSONArray()
                    items.forEach { arr.put(JSONObject().put("id", it.first).put("name", it.second)) }
                    send(Packet("gallery.thumbs", JSONObject().apply {
                        put("port", server.localPort)
                        put("offset", offset)
                        put("hasMore", hasMore)
                        put("items", arr)
                    }))
                    appendLog("Serving ${items.size} thumbnails (${offset + 1}–${offset + items.size} of $total)")

                    server.accept().use { client ->
                        client.tcpNoDelay = true
                        val out = java.io.BufferedOutputStream(client.getOutputStream())
                        for ((id, _) in items) {
                            val uri = android.content.ContentUris.withAppendedId(collection, id)
                            val bytes = try {
                                val bmp = appContext.contentResolver.loadThumbnail(
                                    uri, android.util.Size(256, 256), null
                                )
                                java.io.ByteArrayOutputStream().use { bos ->
                                    bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 72, bos)
                                    bos.toByteArray()
                                }
                            } catch (_: Exception) {
                                ByteArray(0)
                            }
                            val len = java.nio.ByteBuffer.allocate(4).putInt(bytes.size).array()
                            out.write(len)
                            out.write(bytes)
                        }
                        out.flush()
                    }
                }
                appendLog("Gallery thumbnails sent")
            } catch (e: Exception) {
                appendLog("Gallery browse failed: ${e.message}")
            }
        }
    }

    /** Send the photos the user picked in the phone's photo picker to the Mac. */
    fun sendPickedPhotos(uris: List<Uri>) {
        if (_state.value != ConnectionState.PAIRED) return
        appendLog("Sending ${uris.size} picked photo(s) to Mac")
        uris.forEach { sendFile(it) }
    }

    /** Drag-out from the Mac: send the phone's most recent image (photo/screenshot). */
    private fun sendLatestImage() {
        scope.launch {
            try {
                val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                val projection = arrayOf(MediaStore.Images.Media._ID)
                val sort = "${MediaStore.Images.Media.DATE_ADDED} DESC"
                appContext.contentResolver.query(collection, projection, null, null, sort)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID))
                        val uri = android.content.ContentUris.withAppendedId(collection, id)
                        appendLog("Sending latest photo to Mac (drag-out)")
                        sendFile(uri, pull = true)
                    } else {
                        appendLog("No photos found to pull")
                    }
                }
            } catch (e: Exception) {
                appendLog("Pull failed: ${e.message}")
            }
        }
    }

    private fun sendFile(uri: Uri, pull: Boolean = false) {
        scope.launch {
            try {
                val resolver = appContext.contentResolver
                var name = "file"
                var size = -1L
                resolver.query(uri, null, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (nameIndex >= 0) name = cursor.getString(nameIndex) ?: name
                        if (sizeIndex >= 0) size = cursor.getLong(sizeIndex)
                    }
                }
                if (size < 0) {
                    appendLog("Cannot determine size of $name — skipping")
                    return@launch
                }

                ServerSocket(0).use { server ->
                    server.soTimeout = 15000
                    send(Packet("file.offer", JSONObject().apply {
                        put("name", name)
                        put("size", size)
                        put("port", server.localPort)
                        if (pull) put("pull", true)
                    }))
                    _transferStatus.value = "Sending $name…"
                    appendLog("Offering $name (${size / 1024} KB)")

                    server.accept().use { client ->
                        resolver.openInputStream(uri)?.use { input ->
                            val out = client.getOutputStream()
                            val buf = ByteArray(65536)
                            var sent = 0L
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                                sent += n
                                _transferStatus.value =
                                    "Sending $name… ${(sent * 100 / size).coerceAtMost(100)}%"
                            }
                            out.flush()
                        }
                    }
                }
                appendLog("Sent $name ✓")
            } catch (e: Exception) {
                appendLog("Send failed: ${e.message}")
            } finally {
                _transferStatus.value = null
            }
        }
    }

    // MARK: file transfer — receiving (Mac → phone)

    private fun receiveFile(name: String, size: Long, port: Int, dir: String = "") {
        // If a target folder is given and we have all-files access, write there directly
        // (file-manager push). Otherwise fall back to MediaStore Downloads.
        if (dir.isNotEmpty() && hasAllFilesAccess()) {
            receiveFileToDir(name, size, port, dir)
            return
        }
        val host = currentMac?.host ?: return
        scope.launch {
            var savedUri: Uri? = null
            try {
                _transferStatus.value = "Receiving $name…"
                appendLog("Receiving $name (${size / 1024} KB)")

                val resolver = appContext.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name.replace("/", "_"))
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("MediaStore insert failed")
                savedUri = uri

                Socket().use { transferSocket ->
                    transferSocket.connect(InetSocketAddress(host, port), 10000)
                    resolver.openOutputStream(uri)?.use { out ->
                        val input = transferSocket.getInputStream()
                        val buf = ByteArray(65536)
                        var received = 0L
                        while (received < size) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            received += n
                            _transferStatus.value =
                                "Receiving $name… ${(received * 100 / size).coerceAtMost(100)}%"
                        }
                        if (received < size) throw IllegalStateException("Connection closed early")
                    }
                }

                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                appendLog("Received $name → Downloads ✓")
                showNotification("File received", "$name saved to Downloads")
            } catch (e: Exception) {
                appendLog("Receive failed: ${e.message}")
                savedUri?.let { appContext.contentResolver.delete(it, null, null) }
            } finally {
                _transferStatus.value = null
            }
        }
    }

    /** File-manager push: write a Mac file straight into a phone folder. */
    private fun receiveFileToDir(name: String, size: Long, port: Int, dir: String) {
        val host = currentMac?.host ?: return
        scope.launch(kotlinx.coroutines.Dispatchers.IO) {
            val dest = java.io.File(dir, name.replace("/", "_"))
            try {
                _transferStatus.value = "Receiving $name…"
                Socket().use { transferSocket ->
                    transferSocket.connect(InetSocketAddress(host, port), 10000)
                    dest.outputStream().use { out ->
                        val input = transferSocket.getInputStream()
                        val buf = ByteArray(65536)
                        var received = 0L
                        while (received < size) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            received += n
                            _transferStatus.value =
                                "Receiving $name… ${(received * 100 / size).coerceAtMost(100)}%"
                        }
                        if (received < size) throw IllegalStateException("Connection closed early")
                    }
                }
                appendLog("Received $name → $dir ✓")
            } catch (e: Exception) {
                appendLog("Receive failed: ${e.message}")
                dest.delete()
            } finally {
                _transferStatus.value = null
            }
        }
    }

    // MARK: packet handling

    private fun handle(packet: Packet) {
        when (packet.type) {
            "identity" -> {
                packet.body.optString("name").takeIf { it.isNotEmpty() }?.let { _macName.value = it }
            }

            "pair.accept" -> {
                packet.body.optString("token").takeIf { it.isNotEmpty() }?.let { token ->
                    prefs.edit()
                        .putString("pairToken", token)
                        .putString("pairedMacName", _macName.value ?: currentMac?.name)
                        .apply()
                }
                _pairCode.value = null
                _state.value = ConnectionState.PAIRED
                appendLog("Paired with ${_macName.value}")
                startBackgroundService()
                flushPendingShares()
            }

            "pair.reject" -> {
                if (usedTokenForPairing) {
                    // Mac no longer recognizes our token — fall back to the code flow.
                    prefs.edit().remove("pairToken").apply()
                    appendLog("Remembered pairing rejected — asking with a code instead")
                    currentMac?.let { sendPairRequest(it) }
                } else {
                    appendLog("Pairing rejected by Mac")
                    disconnect()
                }
            }

            "clipboard" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val content = packet.body.optString("content")
                val clipboardManager =
                    appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboardManager.setPrimaryClip(ClipData.newPlainText("MacDroid", content))
                _lastReceivedClipboard.value = content
                appendLog("Clipboard ← Mac (${content.length} chars)")
            }

            "ping" -> {
                if (_state.value != ConnectionState.PAIRED) return
                appendLog("Ping from Mac")
                showNotification("Bifrost", packet.body.optString("message", "Ping from your Mac"), sound = true)
            }

            "media.command" -> {
                if (_state.value != ConnectionState.PAIRED) return
                handleMediaCommand(packet.body.optString("action"))
            }

            "file.offer" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val name = packet.body.optString("name", "file")
                val size = packet.body.optLong("size", -1)
                val port = packet.body.optInt("port", -1)
                val dir = packet.body.optString("dir", "")
                if (size >= 0 && port > 0) receiveFile(name, size, port, dir)
            }

            "pull.request" -> {
                if (_state.value != ConnectionState.PAIRED) return
                when (packet.body.optString("kind", "latest_image")) {
                    "pick" -> {
                        // Open the phone's photo picker so the user chooses exact photos.
                        val intent = Intent(appContext, PhotoPickActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        appContext.startActivity(intent)
                    }
                    else -> sendLatestImage()
                }
            }

            "gallery.request" -> {
                if (_state.value != ConnectionState.PAIRED) return
                serveGalleryThumbnails(packet.body.optInt("offset", 0))
            }

            "fs.list" -> {
                if (_state.value != ConnectionState.PAIRED) return
                serveFsList(packet.body.optString("path", ""))
            }

            "fs.pull" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val path = packet.body.optString("path")
                if (path.isNotEmpty()) sendFileFromPath(java.io.File(path))
            }

            "gallery.pull" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val id = packet.body.optLong("id", -1)
                if (id >= 0) {
                    val uri = android.content.ContentUris.withAppendedId(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
                    )
                    sendFile(uri)
                }
            }

            "url" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val url = packet.body.optString("url")
                if (url.startsWith("http://") || url.startsWith("https://")) openUrl(url)
            }

            "audio.start" -> {
                if (_state.value != ConnectionState.PAIRED) return
                if (packet.body.optString("direction") != "speaker") return
                val host = currentMac?.host ?: return
                val port = packet.body.optInt("port", -1)
                if (port <= 0) return
                stopSpeaker()
                val player = SpeakerPlayer(
                    scope = scope,
                    onLog = ::appendLog,
                    onStopped = { _speakerPlaying.value = false },
                )
                speakerPlayer = player
                _speakerPlaying.value = true
                player.start(
                    host, port,
                    packet.body.optInt("sampleRate", 48000),
                    packet.body.optInt("channels", 2)
                )
            }

            "audio.stop" -> {
                if (packet.body.optString("direction") == "speaker") {
                    stopSpeaker()
                    appendLog("Mac audio stream stopped")
                }
            }

            "browse" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val url = packet.body.optString("url")
                if (url.startsWith("http")) {
                    _macTab.value = url to packet.body.optString("title")
                }
            }

            "screen.request" -> {
                if (_state.value != ConnectionState.PAIRED) return
                appendLog("Mac asked to view this screen")
                val intent = Intent(appContext, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                val pending = android.app.PendingIntent.getActivity(
                    appContext, 7, intent, android.app.PendingIntent.FLAG_IMMUTABLE
                )
                val manager =
                    appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(
                    7,
                    NotificationCompat.Builder(appContext, CHANNEL_ID)
                        .setSmallIcon(android.R.drawable.stat_notify_chat)
                        .setContentTitle("Share your screen?")
                        .setContentText("Your Mac wants to view this phone. Tap, then press Share screen.")
                        .setContentIntent(pending)
                        .setPriority(NotificationCompat.PRIORITY_HIGH)
                        .setAutoCancel(true)
                        .build()
                )
            }

            "screen.stop" -> {
                stopScreenShare(notifyMac = false)
            }

            "macscreen.start" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val host = currentMac?.host ?: return
                val port = packet.body.optInt("port", -1)
                val w = packet.body.optInt("width", 0)
                val h = packet.body.optInt("height", 0)
                if (port <= 0 || w <= 0 || h <= 0) return
                pendingMacScreen = Triple(host, port, w to h)
                val intent = Intent(appContext, MacScreenActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(intent)
            }

            "macscreen.stop" -> {
                stopMacScreen(notifyMac = false)
            }

            "screen.input" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val service = RemoteControlService.instance ?: return
                val metrics = appContext.resources.displayMetrics
                val w = metrics.widthPixels
                val h = metrics.heightPixels
                val x = (packet.body.optDouble("x", 0.5) * w).toFloat()
                val y = (packet.body.optDouble("y", 0.5) * h).toFloat()
                when (packet.body.optString("a")) {
                    "tap" -> service.tap(x, y)
                    "swipe" -> {
                        val x2 = (packet.body.optDouble("x2", 0.5) * w).toFloat()
                        val y2 = (packet.body.optDouble("y2", 0.5) * h).toFloat()
                        val ms = packet.body.optLong("ms", 200)
                        service.swipe(x, y, x2, y2, ms)
                    }
                }
            }

            "screen.key" -> {
                if (_state.value != ConnectionState.PAIRED) return
                val service = RemoteControlService.instance ?: return
                val text = packet.body.optString("text")
                val special = packet.body.optString("special")
                if (text.isNotEmpty()) service.typeText(text)
                else if (special.isNotEmpty()) service.pressSpecial(special)
            }
        }
    }

    private fun openUrl(url: String) {
        appendLog("Link from Mac: $url")
        val viewIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (MainActivity.isInForeground) {
            try {
                appContext.startActivity(viewIntent)
                return
            } catch (_: Exception) {
            }
        }
        // App is backgrounded (Android blocks activity starts) — notify instead.
        val manager =
            appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val pending = android.app.PendingIntent.getActivity(
            appContext, url.hashCode(), viewIntent, android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("Link from your Mac")
            .setContentText(url)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        manager.notify(url.hashCode(), notification)
    }

    private fun flushPendingShares() {
        val toSend: List<Uri>
        synchronized(pendingShares) {
            toSend = pendingShares.toList()
            pendingShares.clear()
        }
        toSend.forEach { sendFile(it) }
    }

    private fun startBackgroundService() {
        val intent = Intent(appContext, ConnectionService::class.java)
        appContext.startForegroundService(intent)
    }

    // MARK: plumbing

    private fun send(packet: Packet) {
        writePacket(packet)
    }

    /** Tear down after a connection ends — but only if this session wasn't already superseded. */
    private fun cleanup(mySession: Int, s: Socket?) {
        try {
            s?.close()
        } catch (_: Exception) {
        }
        synchronized(this) {
            if (mySession != sessionId) return
            sessionId++
            micStreamer?.stop()
            micStreamer = null
            _micStreaming.value = false
            stopSpeaker()
            stopScreenShare(notifyMac = false)
            heartbeatJob?.cancel()
            heartbeatJob = null
            socket = null
            handshakeDone = false
            writer = null
            _pairCode.value = null
            _transferStatus.value = null
            if (_state.value != ConnectionState.DISCONNECTED) {
                _state.value = ConnectionState.DISCONNECTED
                appendLog("Disconnected")
            }
        }
    }

    private fun generatePairCode(): String =
        SecureRandom().nextInt(1_000_000).toString().padStart(6, '0')

    private fun createNotificationChannel() {
        val manager =
            appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Bifrost", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Pings and events from your Mac"
            }
        )
        manager.createNotificationChannel(
            NotificationChannel(
                SERVICE_CHANNEL_ID, "MacDroid connection", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the connection to your Mac alive"
            }
        )
    }

    private fun showNotification(title: String, message: String, sound: Boolean = false) {
        val manager =
            appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = NotificationCompat.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(message)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
        if (sound) {
            builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
        }
        manager.notify(System.currentTimeMillis().toInt(), builder.build())
    }

    private fun appendLog(message: String) {
        android.util.Log.d("MacDroid", message)
        val time = android.text.format.DateFormat.format("HH:mm:ss", System.currentTimeMillis())
        _log.value = (_log.value + "[$time] $message").takeLast(200)
    }

    const val CHANNEL_ID = "macdroid"
    const val SERVICE_CHANNEL_ID = "macdroid_service"
    private const val GALLERY_PAGE_SIZE = 60
}
