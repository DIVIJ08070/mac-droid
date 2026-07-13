package com.macdroid.app

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Foreground service that keeps the link to the Mac alive while the app is
 * backgrounded, and automatically reconnects to the remembered Mac when the
 * connection drops (e.g. after Wi-Fi roaming or the Mac app restarting).
 */
class ConnectionService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onCreate() {
        super.onCreate()
        startForegroundWithTypes(includeMic = false, includeScreen = false, text = "Connecting…")

        scope.launch {
            ConnectionManager.state.collect { state ->
                val text = when (state) {
                    ConnectionState.PAIRED -> "Connected to ${ConnectionManager.macName.value ?: "Mac"}"
                    ConnectionState.CONNECTING, ConnectionState.PAIRING -> "Connecting…"
                    ConnectionState.DISCONNECTED -> "Waiting for ${ConnectionManager.rememberedMacName() ?: "Mac"}…"
                }
                updateNotification(text)
            }
        }

        // While the mic streams or the screen is shared, escalate the foreground
        // service type accordingly — Android 14+ blocks both capabilities otherwise.
        scope.launch {
            kotlinx.coroutines.flow.combine(
                ConnectionManager.micStreaming,
                ConnectionManager.screenSharing
            ) { mic, screen -> mic to screen }.collect { (micOn, screenOn) ->
                try {
                    val text = when {
                        screenOn -> "Sharing screen with Mac"
                        micOn -> "Streaming mic to Mac"
                        else -> "Connected to ${ConnectionManager.macName.value ?: "Mac"}"
                    }
                    startForegroundWithTypes(micOn, screenOn, text)
                } catch (e: Exception) {
                    android.util.Log.w("MacDroid", "FGS type change failed: ${e.message}")
                }
            }
        }

        scope.launch { reconnectLoop() }
    }

    private fun startForegroundWithTypes(includeMic: Boolean, includeScreen: Boolean, text: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            if (includeMic) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (includeScreen) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(NOTIFICATION_ID, buildNotification(text), types)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification(text))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_START_SCREEN) {
            // Promote the FGS to include mediaProjection type FIRST, synchronously, so the
            // subsequent getMediaProjection() call is legal on Android 14+.
            try {
                startForegroundWithTypes(
                    includeMic = ConnectionManager.micStreaming.value,
                    includeScreen = true,
                    text = "Sharing screen with Mac"
                )
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                val code = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                if (data != null) ConnectionManager.beginScreenShare(code, data)
            } catch (e: Exception) {
                android.util.Log.w("MacDroid", "Screen share start failed: ${e.message}")
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun reconnectLoop() {
        while (true) {
            val rememberedName = ConnectionManager.rememberedMacName()
            if (ConnectionManager.state.value == ConnectionState.DISCONNECTED &&
                rememberedName != null && ConnectionManager.hasRememberedMac()
            ) {
                val discovery = DiscoveryManager(this)
                try {
                    discovery.start()
                    val target = withTimeoutOrNull(10_000) {
                        discovery.macs
                            .first { list -> list.any { it.name == rememberedName } }
                            .first { it.name == rememberedName }
                    }
                    if (target != null && ConnectionManager.state.value == ConnectionState.DISCONNECTED) {
                        ConnectionManager.connect(target)
                    }
                } finally {
                    discovery.stop()
                }
            }
            delay(8_000)
        }
    }

    private fun buildNotification(text: String): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, ConnectionManager.SERVICE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("MacDroid")
            .setContentText(text)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        private const val NOTIFICATION_ID = 2
        const val ACTION_START_SCREEN = "com.macdroid.app.START_SCREEN"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
    }
}
