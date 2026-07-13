package com.macdroid.app

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * Watches the browser's address bar and syncs the current page to the Mac
 * (Handoff-style). The user enables this once in Settings → Accessibility.
 *
 * Two triggers: accessibility events (fast) and a 2 s poll (catches everything
 * events miss, e.g. same-window navigations Chrome doesn't announce).
 */
class BrowserWatcherService : AccessibilityService() {

    private var lastUrl: String? = null
    private val handler = Handler(Looper.getMainLooper())
    private val poller = object : Runnable {
        override fun run() {
            checkCurrentUrl()
            handler.postDelayed(this, 2000)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        ConnectionManager.init(applicationContext) // safe if already initialized
        Log.d("MacDroid", "BrowserWatcherService connected")
        handler.post(poller)
    }

    override fun onDestroy() {
        handler.removeCallbacks(poller)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        checkCurrentUrl()
    }

    private fun checkCurrentUrl() {
        val root = rootInActiveWindow ?: return
        val packageName = root.packageName?.toString() ?: return
        val urlBarId = URL_BAR_IDS[packageName] ?: return

        val text = root.findAccessibilityNodeInfosByViewId(urlBarId)
            ?.firstOrNull()?.text?.toString()?.trim() ?: return
        if (text.isEmpty() || text.contains(' ') || !text.contains('.')) return // typing / search

        val url = if (text.startsWith("http://") || text.startsWith("https://")) text else "https://$text"
        if (url == lastUrl) return
        lastUrl = url
        Log.d("MacDroid", "Tab sync: $url")
        ConnectionManager.sendBrowse(url)
    }

    override fun onInterrupt() {}

    companion object {
        private val URL_BAR_IDS = mapOf(
            "com.android.chrome" to "com.android.chrome:id/url_bar",
            "com.sec.android.app.sbrowser" to "com.sec.android.app.sbrowser:id/location_bar_edit_text",
        )

        fun isEnabled(context: Context): Boolean {
            val enabled = Settings.Secure.getString(
                context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            return enabled.contains("${context.packageName}/.${BrowserWatcherService::class.simpleName}") ||
                enabled.contains("${context.packageName}/${BrowserWatcherService::class.qualifiedName}")
        }
    }
}
