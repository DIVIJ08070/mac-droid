package com.macdroid.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {

    companion object {
        @Volatile
        var isInForeground = false
    }

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onResume() {
        super.onResume()
        isInForeground = true
    }

    override fun onPause() {
        super.onPause()
        isInForeground = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Black system bars with white (light) icons, edge to edge.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.BLACK),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.BLACK),
        )
        ConnectionManager.init(this)
        requestNotificationPermissionIfNeeded()
        handleShareIntent(intent)

        setContent {
            MacDroidTheme {
                var showOnboarding by remember { mutableStateOf(!OnboardingPrefs.isDone(this)) }
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(MdBlack)
                ) {
                    if (showOnboarding) {
                        OnboardingScreen(onDone = {
                            OnboardingPrefs.setDone(this@MainActivity)
                            showOnboarding = false
                        })
                    } else {
                        MacDroidScreen(onReplayOnboarding = { showOnboarding = true })
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    @Suppress("DEPRECATION")
    private fun handleShareIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                val stream = intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                if (stream != null) {
                    ConnectionManager.shareFiles(listOf(stream))
                    return
                }
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
                if (text != null && (text.startsWith("http://") || text.startsWith("https://"))) {
                    ConnectionManager.sendUrl(text)
                }
            }

            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?.let { ConnectionManager.shareFiles(it) }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

@Composable
fun MacDroidScreen(onReplayOnboarding: () -> Unit) {
    val state by ConnectionManager.state.collectAsState()
    val macName by ConnectionManager.macName.collectAsState()
    var showTouchpad by remember { mutableStateOf(false) }
    val touchpadVisible = state == ConnectionState.PAIRED && showTouchpad

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MdBlack)
            .systemBarsPadding()
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (!touchpadVisible) {
            HomeHeader(state, macName, onReplayOnboarding)
        }
        Box(Modifier.weight(1f)) {
            when (state) {
                ConnectionState.DISCONNECTED -> DiscoveryPane()
                ConnectionState.CONNECTING -> StatusPane("Connecting to your Mac…")
                ConnectionState.PAIRING -> PairingPane()
                ConnectionState.PAIRED ->
                    if (showTouchpad) {
                        TouchpadPane(onBack = { showTouchpad = false })
                    } else {
                        ConnectedPane(onOpenTouchpad = { showTouchpad = true })
                    }
            }
        }
        if (!touchpadVisible) LogPane()
    }
}

@Composable
private fun HomeHeader(
    state: ConnectionState,
    macName: String?,
    onReplayOnboarding: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatusDot(state)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                "MacDroid",
                color = MdWhite,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Light,
                fontSize = 26.sp,
            )
            Text(
                when (state) {
                    ConnectionState.PAIRED -> "Connected to ${macName ?: "Mac"}"
                    ConnectionState.CONNECTING -> "Connecting…"
                    ConnectionState.PAIRING -> "Pairing…"
                    ConnectionState.DISCONNECTED -> "Not connected"
                },
                color = MdWhite40,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
            )
        }
        // Replay onboarding
        Box(
            Modifier
                .size(34.dp)
                .border(1.dp, MdBorder, CircleShape)
                .background(MdSurface, CircleShape)
                .clickable(onClick = onReplayOnboarding),
            contentAlignment = Alignment.Center,
        ) {
            Text("?", color = MdWhite60, fontFamily = FontFamily.Monospace, fontSize = 15.sp)
        }
    }
}

@Composable
private fun StatusDot(state: ConnectionState) {
    when (state) {
        ConnectionState.PAIRED -> StaticDot(MdGreen)
        ConnectionState.DISCONNECTED -> PulsingDot(MdWhite)
        else -> PulsingDot(MdAmber)
    }
}

// MARK: - Screens

@Composable
private fun DiscoveryPane() {
    val context = LocalContext.current
    val discovery = remember { DiscoveryManager(context) }
    val macs by discovery.macs.collectAsState()

    DisposableEffect(Unit) {
        discovery.start()
        onDispose { discovery.stop() }
    }

    // Show a helper card if nothing turns up after a few seconds.
    val showEmptyHint by produceState(initialValue = false) {
        delay(6000)
        value = true
    }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Entrance(0) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PulsingDot(MdWhite, size = 8.dp)
                Spacer(Modifier.width(12.dp))
                SectionLabel("Looking for your Mac")
            }
        }
        Entrance(1) {
            DarkCard {
                Text(
                    "1  Open the MacDroid app on your Mac\n" +
                        "2  Keep both devices on the same Wi-Fi\n" +
                        "3  Your Mac appears below — tap it",
                    color = MdWhite60,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    lineHeight = 24.sp,
                )
            }
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            items(macs, key = { it.name }) { mac ->
                Entrance(2) {
                    DarkCard(onClick = { ConnectionManager.connect(mac) }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    mac.name,
                                    color = MdWhite,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 16.sp,
                                )
                                Text(
                                    mac.host,
                                    color = MdWhite40,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 12.sp,
                                )
                            }
                            PrimaryPill("Connect") { ConnectionManager.connect(mac) }
                        }
                    }
                }
            }
            if (macs.isEmpty() && showEmptyHint) {
                item {
                    Entrance(0) {
                        DarkCard {
                            Text(
                                "No Macs found yet",
                                color = MdWhite,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 14.sp,
                            )
                            Text(
                                "Is MacDroid open on your Mac?\nSame Wi-Fi network?",
                                color = MdWhite40,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                                lineHeight = 18.sp,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusPane(message: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        PulsingDot(MdAmber, size = 10.dp)
        Spacer(Modifier.width(12.dp))
        Text(
            message,
            color = MdWhite,
            fontFamily = FontFamily.Monospace,
            fontSize = 15.sp,
        )
    }
}

@Composable
private fun PairingPane() {
    val code by ConnectionManager.pairCode.collectAsState()
    val macName by ConnectionManager.macName.collectAsState()

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 32.dp)
    ) {
        if (code != null) {
            Entrance(0) { SectionLabel("Pairing with ${macName ?: "Mac"}") }
            Entrance(1) {
                Text(
                    code!!,
                    color = MdWhite,
                    fontSize = 56.sp,
                    fontWeight = FontWeight.Light,
                    fontFamily = FontFamily.Monospace,
                    letterSpacing = 6.sp,
                )
            }
            Entrance(2) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "Check it matches your Mac's screen",
                        color = MdWhite60,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 13.sp,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Then click Accept on the Mac to finish",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                }
            }
        } else {
            Entrance(0) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    PulsingDot(MdAmber, size = 10.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        "Reconnecting to ${macName ?: "Mac"}…",
                        color = MdWhite,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 15.sp,
                    )
                }
            }
        }
        Entrance(3) {
            GhostPill("Cancel") { ConnectionManager.disconnect() }
        }
    }
}

@Composable
private fun ConnectedPane(onOpenTouchpad: () -> Unit) {
    val context = LocalContext.current
    val lastClipboard by ConnectionManager.lastReceivedClipboard.collectAsState()
    val transferStatus by ConnectionManager.transferStatus.collectAsState()
    val micStreaming by ConnectionManager.micStreaming.collectAsState()
    val speakerPlaying by ConnectionManager.speakerPlaying.collectAsState()
    val screenSharing by ConnectionManager.screenSharing.collectAsState()

    val filePicker = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.GetMultipleContents()
    ) { uris -> ConnectionManager.shareFiles(uris) }

    val micPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> if (granted) ConnectionManager.startMic() }

    val screenConsent = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data
        if (result.resultCode == android.app.Activity.RESULT_OK && data != null) {
            // Hand the consent result to the service. It must call startForeground with the
            // mediaProjection type BEFORE getMediaProjection() runs (Android 14+ requirement),
            // so the projection is created inside the service, not here.
            val svc = Intent(context, ConnectionService::class.java).apply {
                action = ConnectionService.ACTION_START_SCREEN
                putExtra(ConnectionService.EXTRA_RESULT_CODE, result.resultCode)
                putExtra(ConnectionService.EXTRA_RESULT_DATA, data)
            }
            ContextCompat.startForegroundService(context, svc)
        }
    }

    Column(
        modifier = Modifier.verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Entrance(0) {
            PrimaryPill(
                "Open Touchpad",
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                onClick = onOpenTouchpad,
            )
        }

        Entrance(1) { SectionLabel("Clipboard & Files", Modifier.padding(top = 8.dp)) }
        Entrance(1) {
            DarkCard {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    GhostPill("Clipboard", Modifier.weight(1f)) { ConnectionManager.sendClipboard() }
                    GhostPill("Files", Modifier.weight(1f)) { filePicker.launch("*/*") }
                }
                GhostPill("Open copied link on Mac", Modifier.fillMaxWidth()) {
                    ConnectionManager.sendClipboardUrl()
                }
                transferStatus?.let {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        PulsingDot(MdWhite, size = 7.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(it, color = MdWhite60, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                    }
                }
                lastClipboard?.let {
                    Text(
                        "Last from Mac: $it",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                        maxLines = 2,
                    )
                }
            }
        }

        Entrance(2) { SectionLabel("Remote", Modifier.padding(top = 8.dp)) }
        Entrance(2) {
            DarkCard {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    GhostPill("Vol −", Modifier.weight(1f), compact = true) { ConnectionManager.sendCommand("volume_down") }
                    GhostPill("Vol +", Modifier.weight(1f), compact = true) { ConnectionManager.sendCommand("volume_up") }
                    GhostPill("Mute", Modifier.weight(1f), compact = true) { ConnectionManager.sendCommand("mute") }
                    GhostPill("⏯", Modifier.weight(1f), compact = true) { ConnectionManager.sendCommand("playpause") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    GhostPill("Lock", Modifier.weight(1f), compact = true) { ConnectionManager.sendCommand("lock") }
                    GhostPill("Sleep", Modifier.weight(1f), compact = true) { ConnectionManager.sendCommand("sleep") }
                    GhostPill("Shot", Modifier.weight(1f), compact = true) { ConnectionManager.sendCommand("screenshot") }
                }
                GhostPill("Ping Mac", Modifier.fillMaxWidth()) { ConnectionManager.pingMac() }
            }
        }

        Entrance(3) { SectionLabel("Audio", Modifier.padding(top = 8.dp)) }
        Entrance(3) {
            DarkCard {
                GhostPill(
                    if (micStreaming) "Stop mic" else "Use as Mac microphone",
                    Modifier.fillMaxWidth(),
                ) {
                    if (micStreaming) {
                        ConnectionManager.stopMic()
                    } else if (ContextCompat.checkSelfPermission(
                            context, Manifest.permission.RECORD_AUDIO
                        ) == PackageManager.PERMISSION_GRANTED
                    ) {
                        ConnectionManager.startMic()
                    } else {
                        micPermission.launch(Manifest.permission.RECORD_AUDIO)
                    }
                }
                if (speakerPlaying) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            "Playing Mac audio",
                            Modifier.weight(1f),
                            color = MdWhite,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 13.sp,
                        )
                        GhostPill("Stop", compact = true) { ConnectionManager.stopSpeaker() }
                    }
                    Text(
                        "Sound plays through this phone — including Bluetooth devices connected to it.",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                } else {
                    Text(
                        "Tip: enable \"Stream Mac audio to phone\" on the Mac to listen through this phone's Bluetooth.",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                }
            }
        }

        Entrance(4) { SectionLabel("Screen", Modifier.padding(top = 8.dp)) }
        Entrance(4) {
            DarkCard {
                GhostPill(
                    if (screenSharing) "Stop sharing screen" else "Share screen to Mac",
                    Modifier.fillMaxWidth(),
                ) {
                    if (screenSharing) {
                        ConnectionManager.stopScreenShare()
                    } else {
                        val mpm = context.getSystemService(
                            android.media.projection.MediaProjectionManager::class.java
                        )
                        screenConsent.launch(mpm.createScreenCaptureIntent())
                    }
                }
                if (screenSharing) {
                    Text(
                        "Live — a viewer window is open on your Mac.",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                }
                GhostPill("View Mac screen here", Modifier.fillMaxWidth()) {
                    ConnectionManager.requestMacScreen()
                }
                val controlEnabled by produceState(initialValue = RemoteControlService.isEnabled(context)) {
                    while (true) { value = RemoteControlService.isEnabled(context); delay(2000) }
                }
                if (controlEnabled) {
                    Text(
                        "✓ Mouse control enabled — click the Mac window to tap, drag to swipe.",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                } else {
                    GhostPill("Enable mouse control") {
                        context.startActivity(
                            Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                }
            }
        }

        Entrance(5) { SectionLabel("Tab Sync", Modifier.padding(top = 8.dp)) }
        Entrance(5) { TabSyncCard() }

        Entrance(6) {
            Row(
                Modifier.padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                GhostPill("Disconnect", Modifier.weight(1f)) { ConnectionManager.userDisconnect() }
                Box(
                    Modifier
                        .weight(1f)
                        .height(40.dp)
                        .clickable { ConnectionManager.forgetMac() },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "Forget this Mac",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 13.sp,
                    )
                }
            }
        }
        Spacer(Modifier.height(4.dp))
    }
}

@Composable
private fun TabSyncCard() {
    val context = LocalContext.current
    val macTab by ConnectionManager.macTab.collectAsState()

    val watcherEnabled by produceState(
        initialValue = BrowserWatcherService.isEnabled(context)
    ) {
        while (true) {
            value = BrowserWatcherService.isEnabled(context)
            delay(2000)
        }
    }

    DarkCard {
        macTab?.let { (url, title) ->
            Text(
                "On your Mac: ${title.ifEmpty { url }}",
                color = MdWhite,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
                maxLines = 2,
            )
            PrimaryPill("Continue here") {
                context.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        } ?: Text(
            "Browse on the Mac and the page appears here.",
            color = MdWhite40,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
        )

        if (watcherEnabled) {
            Text(
                "✓ Your phone's tabs show in the Mac's menu bar.",
                color = MdWhite40,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
            )
        } else {
            GhostPill("Enable phone → Mac sync") {
                context.startActivity(
                    Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        }
    }
}

@Composable
private fun LogPane() {
    val log by ConnectionManager.log.collectAsState()
    if (log.isEmpty()) return

    DarkCard(padding = 10.dp) {
        LazyColumn(
            modifier = Modifier.height(96.dp),
            reverseLayout = true
        ) {
            items(log.reversed()) { line ->
                Text(
                    line,
                    color = MdWhite40,
                    fontSize = 11.sp,
                    lineHeight = 16.sp,
                    fontFamily = FontFamily.Monospace
                )
            }
        }
    }
}
