package com.macdroid.app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

/**
 * Bridges phone calls to the Mac: emits call.state packets (ringing/offhook/idle
 * with caller name + number) and executes call.action packets from the Mac —
 * "silence" mutes the ringer for THIS ring only (the previous ringer mode comes
 * back when the call ends), "decline" rejects the ringing call.
 *
 * Everything degrades gracefully: without READ_PHONE_STATE the protected
 * PHONE_STATE broadcast is simply never delivered, without READ_CALL_LOG the
 * number extra stays empty, without READ_CONTACTS the name stays empty, and
 * without ANSWER_PHONE_CALLS decline is a no-op. No permission → no crash.
 */
object CallBridge {

    private var registered = false

    // "ringing" | "offhook" | "idle" — mirrors the last call.state we saw.
    private var lastState = "idle"
    private var currentNumber = ""

    // Ringer mode before the Mac silenced this ring; restored when the call ends.
    private var savedRingerMode: Int? = null

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /** Register the phone-state receiver once. Safe without any permission —
     *  the protected broadcast just never arrives until the user grants Phone. */
    fun register(appContext: Context) {
        if (registered) return
        registered = true
        val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
        ContextCompat.registerReceiver(
            appContext,
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    try {
                        handlePhoneState(context.applicationContext, intent)
                    } catch (e: Exception) {
                        android.util.Log.w("MacDroid", "Call state handling failed: ${e.message}")
                    }
                }
            },
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    @Suppress("DEPRECATION") // EXTRA_INCOMING_NUMBER: still the way for non-dialer apps
    private fun handlePhoneState(context: Context, intent: Intent) {
        val stateExtra = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        val state = when (stateExtra) {
            TelephonyManager.EXTRA_STATE_RINGING -> "ringing"
            TelephonyManager.EXTRA_STATE_OFFHOOK -> "offhook"
            else -> "idle"
        }
        // Always restore a ringer we silenced, even if the feature was toggled
        // off mid-ring — the user's ringer mode must never stay stuck on silent.
        if (state == "idle") restoreRinger(context)

        if (!ConnectionManager.callsEnabled.value) {
            lastState = state
            currentNumber = ""
            return
        }

        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER).orEmpty()
        // The broadcast often arrives twice per transition (with and without the
        // number) — only forward a real change or a newly-learned number.
        if (state == lastState && (number.isEmpty() || number == currentNumber)) return
        lastState = state
        if (number.isNotEmpty()) currentNumber = number

        val name = if (currentNumber.isEmpty()) "" else lookupName(context, currentNumber)
        ConnectionManager.sendCallState(state, name, currentNumber)
        if (state == "idle") currentNumber = ""
    }

    /** Contacts lookup, on-device only; empty when READ_CONTACTS is missing. */
    private fun lookupName(context: Context, number: String): String {
        if (!granted(context, Manifest.permission.READ_CONTACTS)) return ""
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number)
            )
            context.contentResolver.query(
                uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0).orEmpty() else "" } ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    /** call.action from the Mac. */
    fun handleAction(context: Context, action: String) {
        when (action) {
            "silence" -> silenceRinger(context)
            "decline" -> declineCall(context)
        }
    }

    private fun silenceRinger(context: Context) {
        if (lastState != "ringing") return
        val am = context.getSystemService(AudioManager::class.java) ?: return
        if (savedRingerMode == null) savedRingerMode = am.ringerMode
        try {
            am.ringerMode = AudioManager.RINGER_MODE_SILENT
        } catch (_: Exception) {
            // Silent can require Do Not Disturb access on some phones — vibrate
            // is the closest thing Android lets us do without it.
            try {
                am.ringerMode = AudioManager.RINGER_MODE_VIBRATE
            } catch (_: Exception) {
                savedRingerMode = null
            }
        }
    }

    private fun restoreRinger(context: Context) {
        val saved = savedRingerMode ?: return
        savedRingerMode = null
        try {
            context.getSystemService(AudioManager::class.java)?.ringerMode = saved
        } catch (_: Exception) {
        }
    }

    @Suppress("DEPRECATION") // endCall(): the only non-dialer way to reject a call
    private fun declineCall(context: Context) {
        if (!granted(context, Manifest.permission.ANSWER_PHONE_CALLS)) return
        try {
            context.getSystemService(TelecomManager::class.java)?.endCall()
        } catch (e: Exception) {
            android.util.Log.w("MacDroid", "Decline failed: ${e.message}")
        }
    }
}
