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
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {

    companion object {
        @Volatile
        var isInForeground = false
    }

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    private val mediaPermission =
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
                // Survive config-change recreation so the splash doesn't replay.
                var showSplash by rememberSaveable { mutableStateOf(true) }
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
                    if (showSplash) {
                        SplashScreen(onFinished = { showSplash = false })
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
        // For drag-out of the latest photo from the mirror window.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_IMAGES)
            != PackageManager.PERMISSION_GRANTED
        ) {
            mediaPermission.launch(Manifest.permission.READ_MEDIA_IMAGES)
        }
    }
}

/**
 * Prominent full-screen disclosure shown before the user is sent to enable
 * either Accessibility service (screen control / tab sync). Google requires a
 * clear, in-context explanation of what an AccessibilityService does before the
 * user leaves for system settings. Continue proceeds; Cancel backs out.
 */
@Composable
private fun AccessibilityDisclosureDialog(onContinue: () -> Unit, onCancel: () -> Unit) {
    Dialog(
        onDismissRequest = onCancel,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Column(
            Modifier
                .padding(horizontal = 18.dp, vertical = 36.dp)
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .background(MdBlack, CardShape)
                .border(1.dp, MdBorder, CardShape)
                .padding(22.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            SectionLabel("Accessibility permission")
            Text(
                "Bifrost uses Android's Accessibility service",
                color = MdWhite,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Light,
                fontSize = 22.sp,
                lineHeight = 28.sp,
            )
            Column(
                Modifier
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    "Bifrost uses Android's Accessibility service so your paired Mac can " +
                        "control this phone (trackpad and remote control) and sync the browser " +
                        "tab you have open.",
                    color = MdWhite60,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    lineHeight = 20.sp,
                )
                Text(
                    "It only acts on the input you send from your own Mac and never collects, " +
                        "stores, or shares your data.",
                    color = MdWhite60,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    lineHeight = 20.sp,
                )
                Text(
                    "On the next screen, turn on the Bifrost service you were enabling.",
                    color = MdWhite40,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    lineHeight = 18.sp,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GhostPill("Cancel", Modifier.weight(1f)) { onCancel() }
                PrimaryPill("Continue", Modifier.weight(1f)) { onContinue() }
            }
        }
    }
}

/**
 * A GhostPill that enables one of Bifrost's Accessibility services. Tapping it
 * first shows the prominent Accessibility disclosure (Google requirement);
 * Continue then opens the system Accessibility settings screen.
 */
@Composable
private fun EnableAccessibilityButton(label: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var showDisclosure by remember { mutableStateOf(false) }
    GhostPill(label, modifier) { showDisclosure = true }
    if (showDisclosure) {
        AccessibilityDisclosureDialog(
            onContinue = {
                showDisclosure = false
                context.startActivity(
                    Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            },
            onCancel = { showDisclosure = false },
        )
    }
}

/**
 * Small amber "!" badge shown next to a feature's section label when a
 * permission that feature needs is missing. Tapping it opens the detailed
 * explanation: why the warning is there, "this feature will not work until you
 * grant X", and a jump to the exact settings screen.
 */
@Composable
private fun PermissionBadge(permission: HelpPermission) {
    var show by remember { mutableStateOf(false) }
    Box(
        Modifier
            .padding(start = 8.dp)
            .size(18.dp)
            .border(1.dp, MdAmber.copy(alpha = 0.6f), androidx.compose.foundation.shape.CircleShape)
            .background(MdAmber.copy(alpha = 0.15f), androidx.compose.foundation.shape.CircleShape)
            .clickable { show = true },
        contentAlignment = Alignment.Center,
    ) {
        Text("!", color = MdAmber, fontFamily = FontFamily.Monospace, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
    if (show) PermissionWarningDialog(permission, onDismiss = { show = false })
}

/** Section label with optional trailing "?" help button and permission badge(s). */
@Composable
private fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    help: FeatureHelp? = null,
    badges: @Composable () -> Unit = {},
) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        SectionLabel(title)
        if (help != null) HelpButton(help)
        badges()
    }
}

private fun hasPerm(context: android.content.Context, perm: String) =
    ContextCompat.checkSelfPermission(context, perm) == PackageManager.PERMISSION_GRANTED

private fun hasPhotosAccess(context: android.content.Context) =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        hasPerm(context, Manifest.permission.READ_MEDIA_IMAGES)
    else hasPerm(context, Manifest.permission.READ_EXTERNAL_STORAGE)

private fun hasPostNotifications(context: android.content.Context) =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        hasPerm(context, Manifest.permission.POST_NOTIFICATIONS)

@Composable
fun MacDroidScreen(onReplayOnboarding: () -> Unit) {
    val state by ConnectionManager.state.collectAsState()
    val macName by ConnectionManager.macName.collectAsState()
    var showTouchpad by remember { mutableStateOf(false) }
    var showPresenter by remember { mutableStateOf(false) }
    val fullPane = state == ConnectionState.PAIRED && (showTouchpad || showPresenter)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MdBlack)
            .systemBarsPadding()
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (!fullPane) {
            HomeHeader(state, macName, onReplayOnboarding)
        }
        Box(Modifier.weight(1f)) {
            when (state) {
                ConnectionState.DISCONNECTED -> DiscoveryPane()
                ConnectionState.CONNECTING -> StatusPane("Connecting to your Mac…")
                ConnectionState.PAIRING -> PairingPane()
                ConnectionState.PAIRED ->
                    when {
                        showTouchpad -> TouchpadPane(onBack = { showTouchpad = false })
                        showPresenter -> PresenterPane(onBack = { showPresenter = false })
                        else -> ConnectedPane(
                            onOpenTouchpad = { showTouchpad = true },
                            onOpenPresenter = { showPresenter = true },
                        )
                    }
            }
        }
        if (!fullPane) LogPane()
    }
}

@Composable
private fun PresenterPane(onBack: () -> Unit) {
    var seconds by remember { mutableStateOf(0) }
    var running by remember { mutableStateOf(true) }
    LaunchedEffect(running) {
        while (running) { delay(1000); seconds++ }
    }
    val mm = (seconds / 60).toString().padStart(2, '0')
    val ss = (seconds % 60).toString().padStart(2, '0')

    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            GhostPill("← Back") { onBack() }
            SectionHeader("Presenter", help = HelpContent.presenter)
        }
        // Timer
        DarkCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "$mm:$ss",
                    color = MdWhite,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Light,
                    fontSize = 40.sp,
                    modifier = Modifier.weight(1f),
                )
                GhostPill(if (running) "Pause" else "Resume") { running = !running }
                Spacer(Modifier.width(8.dp))
                GhostPill("Reset") { seconds = 0 }
            }
        }
        Text(
            "Start your slideshow on the Mac, then use these. Works in Keynote, PowerPoint, Google Slides & PDF.",
            color = MdWhite40,
            fontFamily = FontFamily.Monospace,
            fontSize = 11.sp,
        )
        // Big prev / next
        Row(
            Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PresenterBigButton("‹", Modifier.weight(1f)) { ConnectionManager.sendPresent("prev") }
            PresenterBigButton("›", Modifier.weight(1f)) { ConnectionManager.sendPresent("next") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GhostPill("▶ Start") { ConnectionManager.sendPresent("start") }
            GhostPill("⬛ Black") { ConnectionManager.sendPresent("black") }
            GhostPill("■ End") { ConnectionManager.sendPresent("end") }
        }
    }
}

@Composable
private fun PresenterBigButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .fillMaxHeight()
            .background(MdWhite.copy(alpha = 0.06f), androidx.compose.foundation.shape.RoundedCornerShape(18.dp))
            .border(1.dp, MdWhite.copy(alpha = 0.12f), androidx.compose.foundation.shape.RoundedCornerShape(18.dp))
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = MdWhite, fontFamily = FontFamily.Monospace, fontSize = 64.sp, fontWeight = FontWeight.Light)
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
                "Bifrost",
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
                SectionHeader("Looking for your Mac", help = HelpContent.discovery)
            }
        }
        Entrance(1) {
            DarkCard {
                Text(
                    "1  Open the Bifrost app on your Mac\n" +
                        "2  Connect both devices: same Wi-Fi, this\n" +
                        "   phone's hotspot, USB cable, or Tailscale\n" +
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
                                "Is Bifrost open on your Mac?\nSame Wi-Fi or hotspot? USB works too —\nuse Connect by address → 127.0.0.1",
                                color = MdWhite40,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                                lineHeight = 18.sp,
                            )
                        }
                    }
                }
            }
            // Optional, always last: connect away from home by address (e.g. Tailscale).
            item { RemoteConnectCard() }
        }
    }
}

@Composable
private fun RemoteConnectCard() {
    val context = LocalContext.current
    var expanded by remember { mutableStateOf(false) }
    var address by remember { mutableStateOf(ConnectionManager.savedManualAddress() ?: "") }
    var showGuide by remember { mutableStateOf(false) }

    Entrance(3) {
        Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionHeader("Away from home  ·  optional", help = HelpContent.awayFromHome)
            DarkCard(onClick = { expanded = !expanded }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Connect by address",
                            color = MdWhite,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 15.sp,
                        )
                        Text(
                            "Reach your Mac over the internet (Tailscale)",
                            color = MdWhite40,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                        )
                    }
                    Text(
                        if (expanded) "▲" else "▼",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                }
            }

            if (expanded) {
                DarkCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        androidx.compose.material3.OutlinedTextField(
                            value = address,
                            onValueChange = { address = it },
                            placeholder = {
                                Text(
                                    "100.x.y.z  (your Mac's Tailscale IP)",
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 12.sp,
                                )
                            },
                            singleLine = true,
                            textStyle = androidx.compose.ui.text.TextStyle(
                                color = MdWhite, fontFamily = FontFamily.Monospace, fontSize = 14.sp
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            PrimaryPill("Connect") {
                                if (address.isNotBlank()) ConnectionManager.connectManual(address)
                            }
                            GhostPill(if (showGuide) "Hide setup" else "Setup guide") {
                                showGuide = !showGuide
                            }
                        }
                        if (showGuide) {
                            Text(
                                "One-time setup (free):\n\n" +
                                    "1  Install “Tailscale” on this phone and on your Mac (App Store / Play Store).\n" +
                                    "2  Sign in with the same account on both (Google/GitHub/email).\n" +
                                    "3  On the Mac, open Tailscale → copy this Mac's IP (looks like 100.x.y.z).\n" +
                                    "4  Type that IP above and tap Connect. First time asks for a pairing code, like at home.\n\n" +
                                    "Works from anywhere, encrypted. Your home Wi-Fi setup is unaffected — this is just an extra way in.",
                                color = MdWhite60,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                                lineHeight = 19.sp,
                            )
                            GhostPill("Get Tailscale") {
                                context.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse("https://tailscale.com/download"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            }
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
private fun ConnectedPane(onOpenTouchpad: () -> Unit, onOpenPresenter: () -> Unit = {}) {
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

    // Permission states for the per-feature warning badges. Polled so a badge
    // disappears on its own right after the user grants access and comes back.
    val micGranted by produceState(initialValue = hasPerm(context, Manifest.permission.RECORD_AUDIO)) {
        while (true) { value = hasPerm(context, Manifest.permission.RECORD_AUDIO); delay(2000) }
    }
    val photosGranted by produceState(initialValue = hasPhotosAccess(context)) {
        while (true) { value = hasPhotosAccess(context); delay(2000) }
    }
    val postNotifGranted by produceState(initialValue = hasPostNotifications(context)) {
        while (true) { value = hasPostNotifications(context); delay(2000) }
    }
    val mouseControlOn by produceState(initialValue = RemoteControlService.isEnabled(context)) {
        while (true) { value = RemoteControlService.isEnabled(context); delay(2000) }
    }
    val tabWatcherOn by produceState(initialValue = BrowserWatcherService.isEnabled(context)) {
        while (true) { value = BrowserWatcherService.isEnabled(context); delay(2000) }
    }
    val notifAccessOn by produceState(initialValue = NotificationMirrorService.isEnabled(context)) {
        while (true) { value = NotificationMirrorService.isEnabled(context); delay(2000) }
    }
    val allFilesGranted by produceState(initialValue = ConnectionManager.hasAllFilesAccessPublic()) {
        while (true) { value = ConnectionManager.hasAllFilesAccessPublic(); delay(2000) }
    }
    val anyWarning = !photosGranted || !micGranted || !postNotifGranted ||
        !tabWatcherOn || !notifAccessOn || !allFilesGranted

    Column(
        modifier = Modifier.verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Entrance(0) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PrimaryPill(
                    "Open Touchpad",
                    modifier = Modifier
                        .weight(1f)
                        .height(50.dp),
                    onClick = onOpenTouchpad,
                )
                GhostPill(
                    "Presenter",
                    modifier = Modifier
                        .weight(1f)
                        .height(50.dp),
                    onClick = onOpenPresenter,
                )
            }
        }

        // One-line legend, shown above the first section that can carry a
        // warning badge, so the amber "!" explains itself when it first appears.
        if (anyWarning) {
            Entrance(1) { WarningLegend(Modifier.padding(top = 4.dp)) }
        }

        Entrance(1) {
            SectionHeader("Clipboard & Files", Modifier.padding(top = 8.dp), help = HelpContent.clipboardFiles) {
                if (!photosGranted) PermissionBadge(HelpContent.permPhotos)
            }
        }
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

        Entrance(2) { SectionHeader("Remote", Modifier.padding(top = 8.dp), help = HelpContent.remote) }
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

        Entrance(3) {
            SectionHeader("Audio", Modifier.padding(top = 8.dp), help = HelpContent.audio) {
                if (!micGranted) PermissionBadge(HelpContent.permMicrophone)
            }
        }
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

        Entrance(4) {
            // Note: the section's main features (share screen to Mac, view Mac
            // screen) don't need accessibility — only the optional "mouse control"
            // does, and that already has its own inline CTA in the card body.
            SectionHeader("Screen", Modifier.padding(top = 8.dp), help = HelpContent.screen) {
                if (!postNotifGranted) PermissionBadge(HelpContent.permPostNotifications)
            }
        }
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
                if (mouseControlOn) {
                    Text(
                        "✓ Mouse control enabled — click the Mac window to tap, drag to swipe.",
                        color = MdWhite40,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                } else {
                    EnableAccessibilityButton("Enable mouse control")
                }
            }
        }

        Entrance(5) {
            SectionHeader("Tab Sync", Modifier.padding(top = 8.dp), help = HelpContent.tabSync) {
                if (!tabWatcherOn) PermissionBadge(HelpContent.permTabSyncAccessibility)
            }
        }
        Entrance(5) { TabSyncCard(watcherEnabled = tabWatcherOn) }

        Entrance(5) {
            SectionHeader("Notifications", Modifier.padding(top = 8.dp), help = HelpContent.notifications) {
                if (!notifAccessOn) PermissionBadge(HelpContent.permNotificationAccess)
            }
        }
        Entrance(5) { NotificationsCard(accessGranted = notifAccessOn) }

        Entrance(5) {
            SectionHeader("Battery", Modifier.padding(top = 8.dp), help = HelpContent.battery)
        }
        Entrance(5) { BatteryCard() }

        Entrance(5) {
            SectionHeader("Sync", Modifier.padding(top = 8.dp), help = HelpContent.sync) {
                if (!allFilesGranted) PermissionBadge(HelpContent.permAllFiles)
            }
        }
        Entrance(5) { SyncCard() }

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
private fun TabSyncCard(watcherEnabled: Boolean) {
    val context = LocalContext.current
    val macTab by ConnectionManager.macTab.collectAsState()

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
            EnableAccessibilityButton("Enable phone → Mac sync")
        }
    }
}

@Composable
private fun SyncCard() {
    val context = LocalContext.current
    val enabled by ConnectionManager.syncFolder.enabled.collectAsState()
    val status by ConnectionManager.syncFolder.status.collectAsState()
    val allFiles by produceState(initialValue = ConnectionManager.hasAllFilesAccessPublic()) {
        while (true) { value = ConnectionManager.hasAllFilesAccessPublic(); delay(2000) }
    }
    DarkCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Sync folder",
                color = MdWhite,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
            androidx.compose.material3.Switch(
                checked = enabled && allFiles,
                onCheckedChange = { on ->
                    if (on && !allFiles) {
                        ConnectionManager.requestAllFilesAccess()
                    }
                    ConnectionManager.setSyncEnabled(on)
                    if (on) ConnectionManager.broadcastSyncManifest()
                },
            )
        }
        Text(
            "Files in the “Bifrost Sync” folder on this phone mirror to the folder you picked on the Mac — both ways, newest wins. Nothing is ever deleted by sync.",
            color = MdWhite40,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            lineHeight = 18.sp,
        )
        when {
            enabled && !allFiles -> GhostPill("Grant all-files access") {
                ConnectionManager.requestAllFilesAccess()
            }
            enabled && status.isNotEmpty() -> Text(
                "✓ $status",
                color = MdWhite40,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun NotificationsCard(accessGranted: Boolean) {
    val context = LocalContext.current
    val mirroring by ConnectionManager.mirrorNotifications.collectAsState()

    DarkCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Notifications & media on the Mac",
                color = MdWhite,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
            androidx.compose.material3.Switch(
                checked = mirroring && accessGranted,
                onCheckedChange = { on ->
                    if (on && !accessGranted) {
                        context.startActivity(
                            Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                    ConnectionManager.setMirrorNotifications(on)
                },
            )
        }
        if (!accessGranted) {
            Text(
                "Turn this on to mirror notifications AND show what's playing on the Mac. Both need one permission: Notification access.",
                color = MdWhite40,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                lineHeight = 18.sp,
            )
            GhostPill("Grant notification access") {
                context.startActivity(
                    Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        } else if (mirroring) {
            Text(
                "✓ Notifications mirror to the Mac, and Now Playing shows what's on your phone.",
                color = MdWhite40,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                lineHeight = 18.sp,
            )
        } else {
            Text(
                "Access granted. Flip the switch on to mirror notifications + media.",
                color = MdWhite40,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun BatteryCard() {
    DarkCard {
        Text(
            "This phone's battery level and charging state show in the Mac's menu bar automatically — nothing to set up.",
            color = MdWhite40,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            lineHeight = 18.sp,
        )
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
