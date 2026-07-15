package com.macdroid.app

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * Reads posted notifications and forwards them to the Mac (when enabled by the
 * user). Also lets the Mac reply to a message notification by firing its inline
 * reply action. Requires the "Notification access" permission.
 */
class NotificationMirrorService : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        // The framework does NOT replay onNotificationPosted for already-visible
        // notifications on (re)bind, so re-seed the reply map from what's live now.
        // This also drops entries whose PendingIntents went stale across a disconnect.
        reseedReplyActions()
        Log.d("MacDroid", "NotificationMirrorService bound")
    }

    override fun onListenerDisconnected() {
        // Actions can't be fired while disconnected — drop them so they don't leak
        // and so a stale action is never fired after a rebind.
        replyActions.clear()
        if (instance === this) instance = null
        super.onListenerDisconnected()
    }

    /** Rebuild the reply map from the currently-posted notifications. */
    private fun reseedReplyActions() {
        replyActions.clear()
        val active = try { activeNotifications } catch (_: Exception) { null } ?: return
        for (sbn in active) {
            val n = sbn.notification ?: continue
            val replyAction = n.actions?.firstOrNull { action ->
                action.remoteInputs?.any { it.allowFreeFormInput } == true
            } ?: continue
            replyActions[sbn.key] = replyAction
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        instance = this
        if (!ConnectionManager.mirrorNotifications.value) return
        if (sbn.packageName == packageName) return // never mirror our own

        val n = sbn.notification ?: return
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

        // Does this notification carry an inline free-form reply action?
        val replyAction = n.actions?.firstOrNull { action ->
            action.remoteInputs?.any { it.allowFreeFormInput } == true
        }
        val canReply = replyAction != null
        if (canReply) replyActions[sbn.key] = replyAction!! else replyActions.remove(sbn.key)

        ConnectionManager.sendNotification(appName, title, text, sbn.key, canReply)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        replyActions.remove(sbn.key)
        // Tell the Mac to drop the mirrored banner so it can't be replied to after
        // the notification is gone (otherwise the reply would silently fail).
        if (ConnectionManager.mirrorNotifications.value && sbn.packageName != packageName) {
            ConnectionManager.sendNotificationDismiss(sbn.key)
        }
    }

    /** Fire a notification's inline reply action with the Mac-typed message. */
    fun reply(key: String, message: String): Boolean {
        if (message.isBlank()) return false // messaging apps drop empty replies
        val action = replyActions[key] ?: return false
        val inputs = action.remoteInputs ?: return false
        val target = inputs.firstOrNull { it.allowFreeFormInput } ?: return false
        return try {
            val intent = Intent()
            val results = Bundle().apply { putCharSequence(target.resultKey, message) }
            RemoteInput.addResultsToIntent(inputs, intent, results)
            action.actionIntent.send(this, 0, intent)
            Log.d("MacDroid", "Replied to notification $key")
            true
        } catch (e: Exception) {
            Log.w("MacDroid", "Reply failed: ${e.message}")
            false
        }
    }

    companion object {
        @Volatile
        var instance: NotificationMirrorService? = null

        // key → reply action, kept while the notification is live.
        private val replyActions = ConcurrentHashMap<String, Notification.Action>()

        fun isEnabled(context: Context): Boolean {
            val flat = Settings.Secure.getString(
                context.contentResolver, "enabled_notification_listeners"
            ) ?: return false
            val pkg = context.packageName
            return flat.split(":").any { it.startsWith("$pkg/") }
        }
    }
}
