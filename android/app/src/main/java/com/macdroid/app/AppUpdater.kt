package com.macdroid.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * One-tap in-app update: downloads the APK from our site, sanity-checks it
 * (right package, newer version, same signing certificate), then hands it to
 * the system installer. Android itself refuses to install an update whose
 * signature differs from the installed app, so a tampered APK can't replace us
 * even if every in-app check were bypassed.
 */
object AppUpdater {

    sealed class Phase {
        data object Idle : Phase()
        data class Downloading(val progress: Float) : Phase()
        data class NeedsPermission(val message: String) : Phase()
        data class Failed(val message: String) : Phase()
    }

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase

    private const val ALLOWED_HOST = "mac-droid.vercel.app"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun apkFile(ctx: Context) = File(ctx.cacheDir, "updates/bifrost-update.apk")

    /** Remove a stale downloaded APK (call on a cold app start). */
    fun sweep(ctx: Context) {
        if (_phase.value is Phase.Downloading) return // never yank a live download
        runCatching { File(ctx.cacheDir, "updates").deleteRecursively() }
    }

    /** Kick off (or resume) the update: download → validate → system installer. */
    fun install(ctx: Context, url: String) {
        if (_phase.value is Phase.Downloading) return

        // One-time special access: without it the system installer refuses us.
        if (!ctx.packageManager.canRequestPackageInstalls()) {
            _phase.value = Phase.NeedsPermission(
                "Allow “Install unknown apps” for Bifrost, then come back and tap again."
            )
            ctx.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${ctx.packageName}")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }

        val file = apkFile(ctx)
        // Already downloaded and still valid (user came back from the installer
        // or the permission screen)? Skip straight to the install prompt.
        if (file.exists() && validate(ctx, file) == null) {
            _phase.value = Phase.Idle
            launchInstaller(ctx, file)
            return
        }

        _phase.value = Phase.Downloading(0f)
        scope.launch {
            try {
                download(url, file)
                validate(ctx, file)?.let { problem ->
                    file.delete()
                    _phase.value = Phase.Failed(problem)
                    return@launch
                }
                _phase.value = Phase.Idle
                launchInstaller(ctx, file)
            } catch (e: Exception) {
                file.delete()
                _phase.value = Phase.Failed("Download failed: ${e.message ?: "network error"}")
            }
        }
    }

    private fun download(url: String, dest: File) {
        dest.parentFile?.mkdirs()
        // Follow redirects manually so every hop is re-checked against the
        // allowlist — otherwise a redirect could pull bytes from any host.
        var current = url
        var conn: HttpURLConnection
        var hops = 0
        while (true) {
            val parsed = URL(current)
            require(parsed.protocol == "https" && parsed.host == ALLOWED_HOST) {
                "unexpected download source"
            }
            conn = (parsed.openConnection() as HttpURLConnection).apply {
                connectTimeout = 15000
                readTimeout = 30000
                instanceFollowRedirects = false
            }
            val code = conn.responseCode
            if (code in 300..399) {
                val location = conn.getHeaderField("Location")
                conn.disconnect()
                require(++hops <= 5 && location != null) { "too many redirects" }
                current = URL(URL(current), location).toString() // resolve relative redirects
                continue
            }
            require(code in 200..299) { "server returned HTTP $code" }
            break
        }
        try {
            val total = conn.contentLengthLong
            conn.inputStream.use { input ->
                dest.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    var done = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        if (total > 0) {
                            _phase.value = Phase.Downloading(done.toFloat() / total)
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    /** Returns a problem description, or null if the APK looks installable. */
    private fun validate(ctx: Context, file: File): String? {
        val pm = ctx.packageManager
        val info = pm.getPackageArchiveInfo(file.absolutePath, 0)
            ?: return "The downloaded file isn’t a readable APK."
        if (info.packageName != ctx.packageName) {
            return "The downloaded APK is a different app — not installing."
        }
        val current = pm.getPackageInfo(ctx.packageName, 0).longVersionCode
        if (info.longVersionCode <= current) {
            return "Downloaded build isn’t newer than the installed one."
        }
        // Belt-and-braces signature comparison. The OS enforces this at install
        // time regardless; checking here just gives a clearer error earlier.
        val newSigs = pm.getPackageArchiveInfo(
            file.absolutePath, PackageManager.GET_SIGNING_CERTIFICATES
        )?.signingInfo?.apkContentsSigners
        val mySigs = pm.getPackageInfo(
            ctx.packageName, PackageManager.GET_SIGNING_CERTIFICATES
        ).signingInfo?.apkContentsSigners
        // Fail closed: if we can't read either side's signers, don't install.
        // (The OS enforces signature-match at install time regardless; this just
        // gives a clearer, earlier error instead of trusting an unverifiable APK.)
        if (newSigs.isNullOrEmpty() || mySigs.isNullOrEmpty()) {
            return "Couldn’t verify the update’s signature — not installing."
        }
        val sha = MessageDigest.getInstance("SHA-256")
        val a = newSigs.map { sha.digest(it.toByteArray()).toList() }.toSet()
        val b = mySigs.map { sha.digest(it.toByteArray()).toList() }.toSet()
        if (a != b) return "The update’s signature doesn’t match this app — not installing."
        return null
    }

    private fun launchInstaller(ctx: Context, file: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
