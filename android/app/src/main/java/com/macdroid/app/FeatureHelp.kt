package com.macdroid.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

// MARK: - Model

/**
 * One Android permission / special access a feature depends on: why it exists,
 * what breaks without it, and how to grant it. Reused by both the full help
 * sheet and the amber "!" warning badge so the two always tell the same story.
 */
data class HelpPermission(
    val name: String,
    val why: String,
    /** Plain statement of what will NOT work until granted. */
    val blocked: String,
    /** Human path to the toggle, e.g. "Settings → Apps → Bifrost → Microphone". */
    val grantPath: String,
    /** Opens the exact Settings screen; null when there is no toggle (consent dialogs). */
    val openSettings: ((Context) -> Unit)? = null,
)

/** Full help sheet for one feature section. */
data class FeatureHelp(
    val title: String,
    val what: String,
    val howTo: List<String>,
    val permissions: List<HelpPermission> = emptyList(),
    /** Permission the MAC side needs, if any — shown under Permissions. */
    val macSide: String? = null,
    val troubleshoot: String,
)

// MARK: - UI

private val HelpSheetBg = Color(0xFF121214)

/**
 * Small circled "?" that opens the full help sheet for a feature. Same visual
 * language as the intro "?" in the top bar, sized to sit next to a SectionLabel.
 */
@Composable
fun HelpButton(help: FeatureHelp, modifier: Modifier = Modifier) {
    var show by remember { mutableStateOf(false) }
    Box(
        modifier
            .padding(start = 8.dp)
            .size(18.dp)
            .border(1.dp, MdBorder, CircleShape)
            .background(MdSurface, CircleShape)
            .clickable { show = true },
        contentAlignment = Alignment.Center,
    ) {
        Text("?", color = MdWhite60, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
    }
    if (show) HelpDialog(help, onDismiss = { show = false })
}

/** Dismissible dark overlay with the full explanation of one feature. */
@Composable
fun HelpDialog(help: FeatureHelp, onDismiss: () -> Unit) {
    val context = LocalContext.current
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Column(
            Modifier
                .padding(horizontal = 18.dp, vertical = 36.dp)
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .background(HelpSheetBg, CardShape)
                .border(1.dp, MdBorder, CardShape)
                .padding(20.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    SectionLabel("Help")
                    Spacer(Modifier.height(4.dp))
                    Text(
                        help.title,
                        color = MdWhite,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Light,
                        fontSize = 22.sp,
                    )
                }
                Box(
                    Modifier
                        .size(30.dp)
                        .border(1.dp, MdBorder, CircleShape)
                        .background(MdSurface, CircleShape)
                        .clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("✕", color = MdWhite60, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                }
            }
            Spacer(Modifier.height(14.dp))
            Column(
                Modifier
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                HelpSection("What it does") { HelpBody(help.what) }
                HelpSection("How to use") {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        help.howTo.forEachIndexed { i, step ->
                            Row {
                                Text(
                                    "${i + 1}",
                                    color = MdWhite40,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 12.sp,
                                    modifier = Modifier.width(20.dp),
                                )
                                HelpBody(step, Modifier.weight(1f))
                            }
                        }
                    }
                }
                HelpSection("Permissions") {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (help.permissions.isEmpty()) {
                            HelpBody("None needed on this phone.")
                        } else {
                            help.permissions.forEach { p -> PermissionBlock(p, context) }
                        }
                        help.macSide?.let { HelpBody("On the Mac: $it") }
                    }
                }
                HelpSection("If it doesn't work") { HelpBody(help.troubleshoot) }
            }
            Spacer(Modifier.height(16.dp))
            PrimaryPill("Got it", Modifier.fillMaxWidth()) { onDismiss() }
        }
    }
}

@Composable
private fun HelpSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(title)
        content()
    }
}

@Composable
private fun HelpBody(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier = modifier,
        color = MdWhite60,
        fontFamily = FontFamily.Monospace,
        fontSize = 12.sp,
        lineHeight = 18.sp,
    )
}

/** One permission inside the help sheet: why + what breaks + jump to Settings. */
@Composable
private fun PermissionBlock(p: HelpPermission, context: Context) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(MdSurface, CardShape)
            .border(1.dp, MdBorder, CardShape)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(p.name, color = MdWhite, fontFamily = FontFamily.Monospace, fontSize = 13.sp)
        HelpBody(p.why)
        Text(
            p.blocked,
            color = MdAmber,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            lineHeight = 18.sp,
        )
        HelpBody("Grant it: ${p.grantPath}")
        p.openSettings?.let { open ->
            GhostPill("Open settings", compact = true) { open(context) }
        }
    }
}

/**
 * Detailed explanation behind an amber "!" warning badge: why the warning is
 * there, the plain "this will not work until you grant X" statement, and a
 * button to the exact Settings screen.
 */
@Composable
fun PermissionWarningDialog(permission: HelpPermission, onDismiss: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = HelpSheetBg,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(18.dp)
                        .border(1.dp, MdAmber.copy(alpha = 0.6f), CircleShape)
                        .background(MdAmber.copy(alpha = 0.15f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "!",
                        color = MdAmber,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Spacer(Modifier.width(10.dp))
                Text(
                    "${permission.name} needed",
                    color = MdWhite,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 15.sp,
                )
            }
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    permission.why,
                    color = MdWhite60,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    lineHeight = 19.sp,
                )
                Text(
                    permission.blocked,
                    color = MdAmber,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    lineHeight = 19.sp,
                )
                Text(
                    "Grant it: ${permission.grantPath}",
                    color = MdWhite40,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    lineHeight = 18.sp,
                )
            }
        },
        confirmButton = {
            if (permission.openSettings != null) {
                TextButton(onClick = {
                    onDismiss()
                    permission.openSettings.invoke(context)
                }) {
                    Text("Open settings", color = MdWhite, fontFamily = FontFamily.Monospace)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Later", color = MdWhite40, fontFamily = FontFamily.Monospace)
            }
        },
    )
}

/**
 * One-line legend shown above the first section that can carry a warning badge,
 * so the amber "!" explains itself the first time it appears.
 */
@Composable
fun WarningLegend(modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(14.dp)
                .border(1.dp, MdAmber.copy(alpha = 0.6f), CircleShape)
                .background(MdAmber.copy(alpha = 0.15f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "!",
                color = MdAmber,
                fontFamily = FontFamily.Monospace,
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            "= a permission is missing; that feature won't work until you grant it. Tap the badge for details.",
            color = MdWhite40,
            fontFamily = FontFamily.Monospace,
            fontSize = 10.sp,
            lineHeight = 14.sp,
        )
    }
}

// MARK: - Content (facts sourced from the actual implementation)

object HelpContent {

    // ----- Settings jumps -----

    private fun appSettings(context: Context) = context.startActivity(
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    )

    private fun accessibilitySettings(context: Context) = context.startActivity(
        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    )

    private fun notificationListenerSettings(context: Context) = context.startActivity(
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    )

    // ----- Permissions (shared between help sheets and warning badges) -----

    val permPhotos = HelpPermission(
        name = "Photos access",
        why = "From the Mac you can browse this phone's gallery and pull photos without touching the phone, " +
            "and drag the latest photo out of the mirror window. Reading the gallery needs the Photos permission.",
        blocked = "Gallery browsing from the Mac and photo drag-out will not work until you grant Photos access. " +
            "Files and photos you pick by hand on the phone still send fine.",
        grantPath = "Settings → Apps → Bifrost → Permissions → Photos and videos → Allow",
        openSettings = ::appSettings,
    )

    val permMicrophone = HelpPermission(
        name = "Microphone",
        why = "\"Use as Mac microphone\" records your voice with this phone's mic and streams it live to the Mac. " +
            "Android requires the Microphone permission before any app can record.",
        blocked = "This feature will not work until you grant Microphone access — the button will only re-ask.",
        grantPath = "Settings → Apps → Bifrost → Permissions → Microphone (or just tap the feature and allow when asked)",
        openSettings = ::appSettings,
    )

    val permPostNotifications = HelpPermission(
        name = "Notifications",
        why = "When the Mac asks to view this phone's screen, the request arrives as a notification — and background " +
            "streaming shows a quiet status notification. Android 13+ blocks all of these until you allow notifications.",
        blocked = "You will not see the Mac's screen-view requests until you grant Notifications for Bifrost.",
        grantPath = "Settings → Apps → Bifrost → Notifications → Allow",
        openSettings = ::appSettings,
    )

    val permScreenCapture = HelpPermission(
        name = "Screen capture consent",
        why = "Android never lets an app read the screen silently. Every time you tap \"Share screen to Mac\", " +
            "the system shows its screen-recording consent dialog (MediaProjection).",
        blocked = "Nothing is captured or streamed until you accept that system dialog — there is no way around it.",
        grantPath = "No settings toggle — just tap \"Start now\" in the popup when it appears.",
        openSettings = null,
    )

    val permScreenControlAccessibility = HelpPermission(
        name = "Accessibility · \"Bifrost screen control\" (optional)",
        why = "Clicking, dragging and typing into the phone from the Mac's mirror window injects touches via an " +
            "accessibility service — the only no-root way Android allows an app to drive other apps. " +
            "It is only active while you mirror.",
        blocked = "Without it, mirroring still works but is view-only — Mac clicks won't register on the phone.",
        grantPath = "Settings → Accessibility → Bifrost screen control → On",
        openSettings = ::accessibilitySettings,
    )

    val permTabSyncAccessibility = HelpPermission(
        name = "Accessibility · \"Bifrost tab sync\"",
        why = "Android only lets an accessibility service read another app's address bar. Bifrost reads ONLY the " +
            "URL shown in Chrome or Samsung Internet and sends it to your Mac's menu bar — it never reads page " +
            "content, passwords or other apps, and nothing is stored.",
        blocked = "Phone → Mac tab sync will not work until you turn on \"Bifrost tab sync\". " +
            "(Mac → phone handoff works without it.)",
        grantPath = "Settings → Accessibility → Bifrost tab sync → On",
        openSettings = ::accessibilitySettings,
    )

    val permNotificationAccess = HelpPermission(
        name = "Notification access",
        why = "Mirroring reads each notification as it arrives to forward app name, title and text to the Mac, and " +
            "\"reply from the Mac\" fires the notification's own inline-reply action. The same access powers " +
            "Now Playing — the Mac showing and controlling what's playing on this phone.",
        blocked = "Notification mirroring AND Now Playing/media controls on the Mac will not work until you grant " +
            "Notification access to Bifrost.",
        grantPath = "Settings → Notifications → Notification access → Bifrost notifications → Allow",
        openSettings = ::notificationListenerSettings,
    )

    val permAllFiles = HelpPermission(
        name = "All files access",
        why = "The sync folder is Internal storage/Bifrost Sync — a normal shared folder any app can save into. " +
            "Reading and writing arbitrary file types there (not just photos) needs Android's \"All files access\".",
        blocked = "Folder sync will not run until you grant All files access — the switch stays waiting.",
        grantPath = "Settings → Apps → Bifrost → All files access → Allow",
        openSettings = { ConnectionManager.requestAllFilesAccess() },
    )

    // ----- Feature sheets -----

    val presenter = FeatureHelp(
        title = "Presenter",
        what = "Turns this phone into a wireless clicker for slideshows running on your Mac, plus a talk timer. " +
            "Works with Keynote, PowerPoint, Google Slides and full-screen PDFs — the Mac presses the right keys " +
            "in whichever presentation app is frontmost.",
        howTo = listOf(
            "Open your presentation on the Mac, then tap Presenter here.",
            "▶ Start begins the slideshow on the Mac; the big ‹ and › buttons step to the previous / next slide.",
            "⬛ Black blanks the presentation screen mid-talk; ■ End exits the slideshow.",
            "The timer at the top runs only on this phone — Pause/Resume/Reset never touch the Mac.",
        ),
        macSide = "the Bifrost Mac app needs macOS Accessibility permission (System Settings → Privacy & Security → " +
            "Accessibility) to press keys for you — macOS prompts for it on first use.",
        troubleshoot = "Slides not advancing? Click the slideshow window on the Mac once so it has keyboard focus, " +
            "and check the Mac app's Accessibility permission. Google Slides must be the active browser tab, " +
            "in presentation mode.",
    )

    val clipboardFiles = FeatureHelp(
        title = "Clipboard & Files",
        what = "Moves text and files both ways over the direct encrypted connection — no cloud, no size juggling. " +
            "Clipboard puts whatever you last copied on this phone straight into the Mac's clipboard; text copied " +
            "on the Mac shows up under \"Last from Mac\". Files sends any documents you pick, and the Mac can " +
            "browse this phone's photo gallery and pull pictures remotely.",
        howTo = listOf(
            "Copy text anywhere on the phone, tap Clipboard, then paste on the Mac with ⌘V.",
            "Tap Files and pick one or more files — a progress line below tracks the transfer.",
            "From any app: Android's share sheet → Bifrost sends files or links straight to the Mac.",
            "Copied a link? \"Open copied link on Mac\" opens it in the Mac's browser.",
            "On the Mac you can browse this phone's gallery and pull photos; the Mac can also pop this phone's " +
                "photo picker so you choose exactly which shots to send.",
        ),
        permissions = listOf(permPhotos),
        troubleshoot = "Transfers travel over a second direct connection between the devices — guest/hotel Wi-Fi " +
            "with client isolation can block it even when pairing works. If a transfer stalls, check the status " +
            "line, reconnect, or switch to hotspot or the USB link.",
    )

    val remote = FeatureHelp(
        title = "Remote",
        what = "One-tap controls for the Mac: volume down/up, mute, play/pause the current media, lock the screen, " +
            "put the Mac to sleep, and Shot — the Mac takes a screenshot and sends it back to this phone. " +
            "Ping Mac makes the Mac respond so you can check the link. Open Touchpad turns the whole phone " +
            "into a Mac trackpad with full gesture support.",
        howTo = listOf(
            "Tap any pill — it acts on the Mac immediately.",
            "Open Touchpad: 1 finger moves the cursor, tap = click, double-tap & hold = drag.",
            "2 fingers: scroll with momentum fling, pinch = zoom, tap = right-click.",
            "3 fingers: swipe left/right = switch Spaces, up = Mission Control, down = App Exposé, tap = middle-click.",
            "4 fingers: swipe up = Launchpad, down = show desktop. Tune pointer speed with the Speed slider.",
        ),
        macSide = "the Bifrost Mac app needs macOS Accessibility permission to move the cursor, click and press " +
            "keys — macOS prompts for it on first use.",
        troubleshoot = "If clicks or key presses do nothing on the Mac, grant the Mac app Accessibility in " +
            "System Settings → Privacy & Security → Accessibility, then try again.",
    )

    val audio = FeatureHelp(
        title = "Audio",
        what = "Two audio bridges. (1) Use as Mac microphone: this phone's mic streams live to the Mac — handy when " +
            "the Mac has no mic or you want to move around while talking. (2) Mac audio on this phone: enable " +
            "\"Stream Mac audio to phone\" in the Mac app and everything the Mac plays comes out of this phone — " +
            "including Bluetooth headphones paired to the phone, which is the trick for giving an old Mac " +
            "Bluetooth audio.",
        howTo = listOf(
            "Tap \"Use as Mac microphone\" — the first time, Android asks for the Microphone permission.",
            "On the Mac, choose where the mic audio comes out in Bifrost's settings. For Zoom/Meet & co: install " +
                "the free BlackHole driver on the Mac, pick it as Bifrost's mic output, then select BlackHole as " +
                "the microphone inside the app.",
            "Tap \"Stop mic\" to stop streaming.",
            "For Mac → phone audio, flip \"Stream Mac audio to phone\" in the Mac app — a \"Playing Mac audio\" " +
                "row with a Stop button appears here.",
        ),
        permissions = listOf(permMicrophone),
        troubleshoot = "Zoom can't hear you? The chain must be: Bifrost's mic output = BlackHole, and the app's " +
            "input = BlackHole. Choppy audio usually means a weak Wi-Fi link — move closer, or use the USB link.",
    )

    val screen = FeatureHelp(
        title = "Screen",
        what = "Screen mirroring in both directions. \"Share screen to Mac\" streams this phone's display into a " +
            "live window on the Mac — with optional mouse control, so Mac clicks become taps, drags become swipes " +
            "and Mac typing lands in the focused field. \"View Mac screen here\" streams the Mac's display to this " +
            "phone full-screen (view-only — use the Touchpad to control the Mac).",
        howTo = listOf(
            "Share screen to Mac → accept Android's screen-recording consent → a viewer window opens on the Mac.",
            "Optional: \"Enable mouse control\" switches on the Bifrost screen control accessibility service so " +
                "you can drive the phone from the Mac window.",
            "View Mac screen here asks the Mac to mirror; the stream opens full-screen on this phone. " +
                "Leave the viewer (back gesture) to stop it.",
            "Stop sharing anytime with \"Stop sharing screen\".",
        ),
        permissions = listOf(permScreenCapture, permPostNotifications, permScreenControlAccessibility),
        troubleshoot = "Black or frozen viewer? Stop and re-share — the capture consent dies when Android kills " +
            "the app. Mac clicks not registering? Android sometimes disables accessibility services after an app " +
            "update — re-enable \"Bifrost screen control\" in Settings → Accessibility.",
    )

    val tabSync = FeatureHelp(
        title = "Tab Sync",
        what = "Handoff for the web, both ways. Mac → phone: the page you're reading on the Mac appears in this " +
            "card — \"Continue here\" opens it in your phone browser. Phone → Mac: the page you're browsing on " +
            "this phone (Chrome or Samsung Internet) shows in the Mac's menu bar for one-click pickup.",
        howTo = listOf(
            "Mac → phone needs no setup: browse on the Mac and the page appears here.",
            "Phone → Mac: tap \"Enable phone → Mac sync\" and switch on \"Bifrost tab sync\" under " +
                "Settings → Accessibility.",
            "Then just browse — the current page follows you to the Mac's menu bar within a couple of seconds.",
        ),
        permissions = listOf(permTabSyncAccessibility),
        troubleshoot = "Only Chrome and Samsung Internet are supported. Nothing is sent while you're still typing " +
            "in the address bar — only real URLs sync. If it stops after an app update, re-enable the service in " +
            "Settings → Accessibility.",
    )

    val notifications = FeatureHelp(
        title = "Notifications",
        what = "Mirrors this phone's notifications to the Mac as native banners, and messages with an inline reply " +
            "can be answered straight from the Mac keyboard — the reply is delivered through the app's own " +
            "notification action on this phone. The same access drives Now Playing on the Mac: see and control " +
            "the music or podcast playing here. Ongoing/silent notifications and group summaries are skipped, " +
            "and Bifrost never mirrors its own.",
        howTo = listOf(
            "Flip the switch — the first time it opens Android's Notification access page; allow " +
                "\"Bifrost notifications\".",
            "Back in the app, turn the switch on. New notifications now appear on the Mac as they arrive.",
            "Reply from a Mac banner and the messaging app on this phone sends it.",
            "Dismissing a notification on the phone removes the mirrored banner on the Mac too.",
        ),
        permissions = listOf(permNotificationAccess),
        troubleshoot = "Notifications stopped arriving on the Mac? Toggle Notification access off and on (Android " +
            "occasionally unbinds listeners), then flip the switch again. Replies only work while the original " +
            "notification is still visible on the phone.",
    )

    val sync = FeatureHelp(
        title = "Sync folder",
        what = "Keeps one folder mirrored between the devices: Internal storage/Bifrost Sync on this phone ↔ the " +
            "folder you picked in the Mac app. Every ~10 seconds both sides swap file lists and pull whatever is " +
            "missing or newer — the newest edit wins. Sync never deletes: removing a file on one side won't remove " +
            "it on the other. Before a file is overwritten, the old version is kept in a hidden .bifrost-trash " +
            "folder inside Bifrost Sync, so an accidental overwrite is always recoverable. Up to 1000 files sync; " +
            "hidden dot-files are skipped.",
        howTo = listOf(
            "Flip the switch and grant All files access when Android asks.",
            "Drop files into Internal storage/Bifrost Sync with any file manager, or save there from any app.",
            "Within ~10 seconds they appear in the Mac's sync folder — and files added on the Mac appear here.",
            "The status line under the switch shows \"Up to date\" or what's still copying.",
            "Overwrote something by accident? Recover the older copy from Bifrost Sync/.bifrost-trash " +
                "(turn on \"show hidden files\" in your file manager).",
        ),
        permissions = listOf(permAllFiles),
        troubleshoot = "A file not syncing? Names starting with a dot are skipped, only the first 1000 files sync, " +
            "and both devices must be connected. Deletions never propagate by design — sync only adds and updates.",
    )

    val discovery = FeatureHelp(
        title = "Finding your Mac",
        what = "How the two devices meet. Four ways, all direct and encrypted — no account, no cloud: " +
            "1) Same Wi-Fi — the Mac announces itself on the local network (Bonjour) and shows up in the list. " +
            "2) Phone hotspot — turn on this phone's hotspot, join the Mac to it, same list. " +
            "3) USB cable — enable USB debugging on this phone (Settings → Developer options), plug in, and click " +
            "\"Set up the USB link\" in the Mac app; the phone then reaches the Mac through the cable at " +
            "127.0.0.1, port 52377 — no network needed at all. " +
            "4) Tailscale — connect from anywhere with \"Connect by address\" below.",
        howTo = listOf(
            "Open the Bifrost app on the Mac.",
            "Put both devices on the same network (or use hotspot, USB, or Tailscale).",
            "Tap your Mac when it appears in the list.",
            "First time only: a 6-digit code shows on both screens — check they match, then click Accept on the Mac.",
            "That's it, forever: you pair once, and Bifrost reconnects automatically in the background from then on.",
        ),
        troubleshoot = "No Macs listed? Confirm the Mac app is open and both devices share a network. Guest, hotel " +
            "and office Wi-Fi often block device-to-device traffic — use the USB cable or the phone's hotspot " +
            "instead. USB not auto-connecting? Check USB debugging is on, re-plug, or use Connect by address → " +
            "127.0.0.1.",
    )

    val awayFromHome = FeatureHelp(
        title = "Connect by address",
        what = "Reaches your Mac when you're NOT on the same network — from work, a café, anywhere. The recommended " +
            "way is Tailscale: a free app that builds a private encrypted network between your own devices, giving " +
            "the Mac a stable address that looks like 100.x.y.z. The field also accepts any address Bifrost can " +
            "reach directly, as host or host:port (default port 52377) — 127.0.0.1 works for the USB link.",
        howTo = listOf(
            "Install Tailscale on this phone and on the Mac (App Store / Play Store); sign in with the same " +
                "account on both.",
            "On the Mac, open Tailscale and copy the Mac's address (looks like 100.x.y.z).",
            "Type it in the field and tap Connect — the address is remembered for next time.",
            "If this Mac was never paired before, the usual 6-digit code check runs once.",
        ),
        troubleshoot = "Can't connect? Make sure Tailscale is switched ON on both devices and both show as online " +
            "in the Tailscale app. Your home Wi-Fi setup is unaffected — this is just an extra way in. " +
            "(Tailscale itself asks for Android's VPN permission when you first turn it on.)",
    )
}
