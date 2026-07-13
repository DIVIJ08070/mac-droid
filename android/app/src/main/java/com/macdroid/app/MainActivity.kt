package com.macdroid.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
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
import androidx.compose.ui.graphics.Color
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
        ConnectionManager.init(this)
        requestNotificationPermissionIfNeeded()
        handleShareIntent(intent)

        setContent {
            val dark = isSystemInDarkTheme()
            val colorScheme = when {
                Build.VERSION.SDK_INT >= 31 && dark -> dynamicDarkColorScheme(this)
                Build.VERSION.SDK_INT >= 31 -> dynamicLightColorScheme(this)
                dark -> darkColorScheme()
                else -> lightColorScheme()
            }
            MaterialTheme(colorScheme = colorScheme) {
                MacDroidScreen()
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MacDroidScreen() {
    val state by ConnectionManager.state.collectAsState()
    val macName by ConnectionManager.macName.collectAsState()
    var showTouchpad by remember { mutableStateOf(false) }
    val touchpadVisible = state == ConnectionState.PAIRED && showTouchpad

    Scaffold(
        topBar = {
            if (!touchpadVisible) {
                TopAppBar(title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StatusDot(state)
                        Spacer(Modifier.width(10.dp))
                        Column {
                            Text("MacDroid", style = MaterialTheme.typography.titleLarge)
                            Text(
                                when (state) {
                                    ConnectionState.PAIRED -> "Connected to ${macName ?: "Mac"}"
                                    ConnectionState.CONNECTING -> "Connecting…"
                                    ConnectionState.PAIRING -> "Pairing…"
                                    ConnectionState.DISCONNECTED -> "Not connected"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                })
            }
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
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
}

@Composable
private fun StatusDot(state: ConnectionState) {
    val color = when (state) {
        ConnectionState.PAIRED -> Color(0xFF34C759)
        ConnectionState.DISCONNECTED -> MaterialTheme.colorScheme.outline
        else -> Color(0xFFFF9F0A)
    }
    Box(
        Modifier
            .size(12.dp)
            .background(color, CircleShape)
    )
}

@Composable
private fun SectionCard(
    title: String,
    subtitle: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            subtitle?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            content()
        }
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

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionCard("Connect your Mac") {
            Text(
                "1.  Open the MacDroid app on your Mac\n" +
                    "2.  Keep both devices on the same Wi-Fi\n" +
                    "3.  Your Mac will appear below — tap Connect",
                style = MaterialTheme.typography.bodyMedium
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                Text(
                    "Searching your network…",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(macs, key = { it.name }) { mac ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        Modifier.padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("💻  ${mac.name}", style = MaterialTheme.typography.titleMedium)
                            Text(
                                mac.host,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Button(onClick = { ConnectionManager.connect(mac) }) {
                            Text("Connect")
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
        CircularProgressIndicator(modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Text(message, style = MaterialTheme.typography.titleMedium)
    }
}

@Composable
private fun PairingPane() {
    val code by ConnectionManager.pairCode.collectAsState()
    val macName by ConnectionManager.macName.collectAsState()

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        if (code != null) {
            Text("Pairing with ${macName ?: "Mac"}", style = MaterialTheme.typography.titleMedium)
            Text(
                code!!,
                fontSize = 44.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace
            )
            Text(
                "Click Accept on your Mac to finish",
                style = MaterialTheme.typography.bodyMedium
            )
        } else {
            Text(
                "Reconnecting to ${macName ?: "Mac"}…",
                style = MaterialTheme.typography.titleMedium
            )
        }
        OutlinedButton(onClick = { ConnectionManager.disconnect() }) {
            Text("Cancel")
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

    val filePicker = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.GetMultipleContents()
    ) { uris -> ConnectionManager.shareFiles(uris) }

    val micPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> if (granted) ConnectionManager.startMic() }

    Column(
        modifier = Modifier.verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Button(onClick = onOpenTouchpad, modifier = Modifier.fillMaxWidth()) {
            Text("🖱   Open Touchpad", style = MaterialTheme.typography.titleMedium)
        }

        SectionCard("Share", "Move things between your devices") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { ConnectionManager.sendClipboard() }, Modifier.weight(1f)) {
                    Text("📋 Clipboard")
                }
                Button(onClick = { filePicker.launch("*/*") }, Modifier.weight(1f)) {
                    Text("📁 Files")
                }
            }
            Button(
                onClick = { ConnectionManager.sendClipboardUrl() },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("🔗 Open copied link on Mac")
            }
            transferStatus?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(it, style = MaterialTheme.typography.bodySmall)
                }
            }
            lastClipboard?.let {
                Text(
                    "Last from Mac: $it",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2
                )
            }
        }

        SectionCard("Mac remote", "Control your Mac from here") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { ConnectionManager.sendCommand("volume_down") }, Modifier.weight(1f)) { Text("Vol −") }
                OutlinedButton(onClick = { ConnectionManager.sendCommand("volume_up") }, Modifier.weight(1f)) { Text("Vol +") }
                OutlinedButton(onClick = { ConnectionManager.sendCommand("mute") }, Modifier.weight(1f)) { Text("Mute") }
                OutlinedButton(onClick = { ConnectionManager.sendCommand("playpause") }, Modifier.weight(1f)) { Text("⏯") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { ConnectionManager.sendCommand("lock") }, Modifier.weight(1f)) { Text("🔒 Lock") }
                OutlinedButton(onClick = { ConnectionManager.sendCommand("sleep") }, Modifier.weight(1f)) { Text("😴 Sleep") }
                OutlinedButton(onClick = { ConnectionManager.sendCommand("screenshot") }, Modifier.weight(1f)) { Text("📸 Shot") }
            }
            Button(onClick = { ConnectionManager.pingMac() }, modifier = Modifier.fillMaxWidth()) {
                Text("🔔 Ping Mac")
            }
        }

        SectionCard("Audio", "Use your phone as the Mac's mic and speaker") {
            Button(
                onClick = {
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
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(if (micStreaming) "⏹ Stop mic" else "🎤 Use as Mac microphone")
            }
            if (speakerPlaying) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("🔊 Playing Mac audio", Modifier.weight(1f))
                    OutlinedButton(onClick = { ConnectionManager.stopSpeaker() }) { Text("Stop") }
                }
                Text(
                    "Sound plays through this phone — including Bluetooth devices connected to it.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                Text(
                    "Tip: enable \"Stream Mac audio to phone\" on the Mac to listen through this phone's Bluetooth.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        TabSyncCard()

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { ConnectionManager.userDisconnect() }, Modifier.weight(1f)) {
                Text("Disconnect")
            }
            TextButton(onClick = { ConnectionManager.forgetMac() }, Modifier.weight(1f)) {
                Text("Forget this Mac")
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

    SectionCard("Tab sync", "Continue browsing on the other device") {
        macTab?.let { (url, title) ->
            Text(
                "🌐 On your Mac: ${title.ifEmpty { url }}",
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2
            )
            Button(onClick = {
                context.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }) { Text("Continue here") }
        } ?: Text(
            "Browse on the Mac and the page appears here.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        if (watcherEnabled) {
            Text(
                "✓ Your phone's tabs show in the Mac's menu bar.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            OutlinedButton(onClick = {
                context.startActivity(
                    Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }) { Text("Enable phone → Mac sync") }
        }
    }
}

@Composable
private fun LogPane() {
    val log by ConnectionManager.log.collectAsState()
    if (log.isEmpty()) return

    Card(modifier = Modifier.fillMaxWidth()) {
        LazyColumn(
            modifier = Modifier
                .padding(10.dp)
                .height(96.dp),
            reverseLayout = true
        ) {
            items(log.reversed()) { line ->
                Text(
                    line,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace
                )
            }
        }
    }
}
