package com.macdroid.app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
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
 * While a call is active (offhook) the Mac can also manage it: "hangup" ends the
 * active call, "mute"/"unmute" toggle the call microphone, and
 * "speaker_on"/"speaker_off" toggle the speakerphone. Every offhook call.state
 * carries the phone's REAL {muted, speaker} state, and any mute/speaker action
 * re-emits call.state with the resulting real values so the Mac toggles never lie.
 *
 * Everything degrades gracefully: without READ_PHONE_STATE the protected
 * PHONE_STATE broadcast is simply never delivered, without READ_CALL_LOG the
 * number extra stays empty, without READ_CONTACTS the name stays empty, and
 * without ANSWER_PHONE_CALLS decline/hangup are no-ops. Mute/speaker are
 * best-effort — if the OS refuses, the real (unchanged) state is reported rather
 * than lying or crashing. No permission → no crash.
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
        if (state == "offhook") {
            ConnectionManager.sendCallState(state, name, currentNumber, isMuted(context), isSpeakerOn(context))
        } else {
            ConnectionManager.sendCallState(state, name, currentNumber)
        }
        if (state == "idle") currentNumber = ""
    }

    /** Push the CURRENT call state to the Mac on (re)connect, so a call already
     *  in progress when the link comes up still shows the banner. Reads the live
     *  system state (not just our last-seen broadcast) so it's correct even if the
     *  app process restarted mid-call — the number may be unknown then, but the
     *  banner and Hang up still work. */
    fun sendCurrentState(context: Context) {
        if (!ConnectionManager.callsEnabled.value) return
        if (!granted(context, Manifest.permission.READ_PHONE_STATE)) return
        val tm = context.getSystemService(TelephonyManager::class.java) ?: return
        val state = try {
            @Suppress("DEPRECATION") // callState: fine for a non-dialer app with READ_PHONE_STATE
            when (tm.callState) {
                TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
                TelephonyManager.CALL_STATE_RINGING -> "ringing"
                else -> return // idle → nothing to show
            }
        } catch (e: Exception) {
            return
        }
        lastState = state
        val name = if (currentNumber.isEmpty()) "" else lookupName(context, currentNumber)
        if (state == "offhook") {
            ConnectionManager.sendCallState(state, name, currentNumber, isMuted(context), isSpeakerOn(context))
        } else {
            ConnectionManager.sendCallState(state, name, currentNumber)
        }
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
            // decline (ringing) and hangup (offhook) are the same TelecomManager
            // call — endCall() ends whichever call is current.
            "decline", "hangup" -> endCall(context)
            "mute" -> setMic(context, true)
            "unmute" -> setMic(context, false)
            "speaker_on" -> setSpeaker(context, true)
            "speaker_off" -> setSpeaker(context, false)
        }
    }

    // MARK: ongoing-call controls (best-effort — never crash if the OS refuses)

    /** Toggle the call microphone, then re-emit real state so the Mac reflects truth. */
    private fun setMic(context: Context, mute: Boolean) {
        val am = context.getSystemService(AudioManager::class.java)
        try {
            am?.isMicrophoneMute = mute
        } catch (e: Exception) {
            android.util.Log.w("MacDroid", "Mic mute failed: ${e.message}")
        }
        reEmitState(context)
    }

    /** Toggle speakerphone vs earpiece, then re-emit real state. */
    @Suppress("DEPRECATION") // setSpeakerphoneOn is the only pre-API-31 route
    private fun setSpeaker(context: Context, on: Boolean) {
        val am = context.getSystemService(AudioManager::class.java) ?: run {
            reEmitState(context); return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (on) {
                    val speaker = am.availableCommunicationDevices
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    if (speaker != null) am.setCommunicationDevice(speaker)
                } else {
                    // Earpiece: clearing the override lets the platform pick the
                    // default route (earpiece for a normal in-call), but prefer the
                    // built-in earpiece explicitly when it's available.
                    val earpiece = am.availableCommunicationDevices
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                    if (earpiece != null) am.setCommunicationDevice(earpiece)
                    else am.clearCommunicationDevice()
                }
            } else {
                am.isSpeakerphoneOn = on
            }
        } catch (e: Exception) {
            android.util.Log.w("MacDroid", "Speaker toggle failed: ${e.message}")
        }
        reEmitState(context)
    }

    /** Real mic-mute state. */
    private fun isMuted(context: Context): Boolean = try {
        context.getSystemService(AudioManager::class.java)?.isMicrophoneMute ?: false
    } catch (_: Exception) {
        false
    }

    /** Real speakerphone state. */
    @Suppress("DEPRECATION") // isSpeakerphoneOn is the only pre-API-31 route
    private fun isSpeakerOn(context: Context): Boolean = try {
        val am = context.getSystemService(AudioManager::class.java) ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.communicationDevice?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        } else {
            am.isSpeakerphoneOn
        }
    } catch (_: Exception) {
        false
    }

    /** Re-send call.state with the current real audio state after a mute/speaker action. */
    private fun reEmitState(context: Context) {
        if (lastState != "offhook") return
        val name = if (currentNumber.isEmpty()) "" else lookupName(context, currentNumber)
        ConnectionManager.sendCallState(
            "offhook", name, currentNumber, isMuted(context), isSpeakerOn(context)
        )
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

    /** Ends the current call — rejects it while ringing (decline), ends it while
     *  active (hangup). endCall() targets whichever call is current, so one path
     *  serves both. */
    @Suppress("DEPRECATION") // endCall(): the only non-dialer way to end a call
    private fun endCall(context: Context) {
        if (!granted(context, Manifest.permission.ANSWER_PHONE_CALLS)) return
        try {
            context.getSystemService(TelecomManager::class.java)?.endCall()
        } catch (e: Exception) {
            android.util.Log.w("MacDroid", "End call failed: ${e.message}")
        }
    }
}
