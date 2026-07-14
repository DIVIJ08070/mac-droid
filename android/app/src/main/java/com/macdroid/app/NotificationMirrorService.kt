package com.macdroid.app

import android.app.Notification
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Reads posted notifications and forwards them to the Mac (when enabled by the
 * user). Requires the special "Notification access" permission, granted once in
 * Settings → Notifications → Device & app notifications → Notification access.
 */
class NotificationMirrorService : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!ConnectionManager.mirrorNotifications.value) return
        if (sbn.packageName == packageName) return // never mirror our own

        val n = sbn.notification ?: return
        // Skip ongoing/foreground-service and group-summary noise.
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return

        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return

        val appName = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(sbn.packageName, 0)
            ).toString()
        } catch (_: Exception) {
            sbn.packageName
        }

        ConnectionManager.sendNotification(appName, title, text)
    }

    companion object {
        fun isEnabled(context: Context): Boolean {
            val flat = Settings.Secure.getString(
                context.contentResolver, "enabled_notification_listeners"
            ) ?: return false
            val pkg = context.packageName
            return flat.split(":").any { it.startsWith("$pkg/") }
        }
    }
}
