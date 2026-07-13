package com.macdroid.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Injects taps and swipes dispatched from the Mac's screen-mirror window.
 * Accessibility gesture dispatch is the only no-root way for an app to drive
 * touch input in other apps. The user enables this once in Settings.
 */
class RemoteControlService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d("MacDroid", "RemoteControlService connected")
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {}
    override fun onInterrupt() {}

    fun tap(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 60)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs.coerceIn(30, 2000))
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    /** Insert typed text at the caret of the focused editable field. */
    fun typeText(text: String) {
        val node = focusedEditable() ?: return
        val current = node.text?.toString() ?: ""
        val start = node.textSelectionStart.let { if (it < 0) current.length else it }
        val end = node.textSelectionEnd.let { if (it < 0) current.length else it }
        val lo = minOf(start, end).coerceIn(0, current.length)
        val hi = maxOf(start, end).coerceIn(0, current.length)
        val updated = current.substring(0, lo) + text + current.substring(hi)
        setNodeText(node, updated, lo + text.length)
    }

    fun pressSpecial(special: String) {
        when (special) {
            "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "space" -> typeText(" ")
            "enter" -> {
                val node = focusedEditable()
                if (node != null && node.isMultiLine) typeText("\n")
                else node?.performAction(
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                )
            }
            "backspace" -> {
                val node = focusedEditable() ?: return
                val current = node.text?.toString() ?: ""
                val caret = node.textSelectionEnd.let { if (it < 0) current.length else it }
                    .coerceIn(0, current.length)
                if (caret > 0) {
                    val updated = current.removeRange(caret - 1, caret)
                    setNodeText(node, updated, caret - 1)
                }
            }
        }
    }

    private fun focusedEditable(): AccessibilityNodeInfo? {
        val node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        return if (node != null && node.isEditable) node else null
    }

    private fun setNodeText(node: AccessibilityNodeInfo, text: String, caret: Int) {
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        val sel = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, caret)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, caret)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
    }

    companion object {
        @Volatile
        var instance: RemoteControlService? = null

        fun isEnabled(context: Context): Boolean {
            val enabled = Settings.Secure.getString(
                context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            return enabled.contains("${context.packageName}/${RemoteControlService::class.qualifiedName}") ||
                enabled.contains("${context.packageName}/.${RemoteControlService::class.simpleName}")
        }
    }
}
