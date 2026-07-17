package com.macdroid.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
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
        // Never leave a stuck cursor if the service is disabled mid-control.
        cursorView?.let { runCatching { windowManager.removeView(it) } }
        cursorView = null
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

    fun longTap(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 600)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    // ---- Universal Control: a Mac-driven cursor overlay on the phone ----
    private val main = Handler(Looper.getMainLooper())
    private val windowManager by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }
    private var cursorView: View? = null
    private var cursorX = 0f
    private var cursorY = 0f
    private var screenW = 0
    private var screenH = 0
    private var density = 1f
    private var dragAnchorX = 0f
    private var dragAnchorY = 0f
    private var leftPush = 0f

    /** Full physical display size, matching the gesture/overlay coordinate space. */
    private fun realScreenSize(): Pair<Int, Int> =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            val b = windowManager.maximumWindowMetrics.bounds
            b.width() to b.height()
        } else {
            val dm = android.util.DisplayMetrics()
            @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealMetrics(dm)
            dm.widthPixels to dm.heightPixels
        }

    /** Show the cursor overlay, centered — the Mac now drives it. */
    fun startControl() {
        val (w, h) = realScreenSize()
        screenW = w
        screenH = h
        density = resources.displayMetrics.density
        cursorX = screenW / 2f
        cursorY = screenH / 2f
        leftPush = 0f
        main.post {
            if (cursorView != null) return@post
            val v = CursorView(this)
            val size = (28 * density).toInt()
            val lp = WindowManager.LayoutParams(
                size, size,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                x = cursorX.toInt()
                y = cursorY.toInt()
            }
            try {
                windowManager.addView(v, lp)
                cursorView = v
            } catch (e: Exception) {
                Log.w("MacDroid", "Cursor overlay failed: ${e.message}")
            }
        }
    }

    fun stopControl() {
        main.post {
            cursorView?.let { runCatching { windowManager.removeView(it) } }
            cursorView = null
        }
    }

    fun moveCursor(dx: Float, dy: Float) {
        // Deltas arrive in Mac points; scale by density so speed feels the same
        // regardless of the phone's pixel density.
        val ndx = dx * density
        cursorX = (cursorX + ndx).coerceIn(0f, screenW.toFloat())
        cursorY = (cursorY + dy * density).coerceIn(0f, screenH.toFloat())
        // Push off the LEFT edge → hand the cursor back to the Mac (mirrors the
        // Mac's slide-off-the-right-edge entry).
        if (cursorX <= 0f && ndx < 0f) {
            leftPush += -ndx
            if (leftPush >= 45f * density) {
                leftPush = 0f
                ConnectionManager.requestControlExit()
            }
        } else if (cursorX > 8f * density) {
            leftPush = 0f
        }
        main.post {
            val v = cursorView ?: return@post
            val lp = v.layoutParams as? WindowManager.LayoutParams ?: return@post
            lp.x = cursorX.toInt()
            lp.y = cursorY.toInt()
            runCatching { windowManager.updateViewLayout(v, lp) }
        }
    }

    /** Right-click → long-press at the cursor. */
    fun longClickAtCursor() = longTap(cursorX, cursorY)

    /** Mouse-down: remember where a drag would start from. */
    fun pressCursor() {
        dragAnchorX = cursorX
        dragAnchorY = cursorY
    }

    /** Mouse-up: a real drag → swipe from the press point to here; else a tap. */
    fun releaseCursor(drag: Boolean) {
        if (drag) {
            val dist = kotlin.math.hypot(
                (cursorX - dragAnchorX).toDouble(), (cursorY - dragAnchorY).toDouble()
            )
            val ms = (dist / 2).toLong().coerceIn(50, 800)
            swipe(dragAnchorX, dragAnchorY, cursorX, cursorY, ms)
        } else {
            tap(cursorX, cursorY)
        }
    }

    /** Scroll wheel → a short swipe at the cursor (positive dy scrolls up). */
    fun scrollAtCursor(dy: Float) {
        val to = (cursorY + dy * density).coerceIn(0f, screenH.toFloat())
        if (kotlin.math.abs(to - cursorY) >= 4f) swipe(cursorX, cursorY, cursorX, to, 90)
    }

    /** A simple arrow pointer drawn with its tip at the view's top-left. */
    private class CursorView(context: Context) : View(context) {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK; style = Paint.Style.STROKE
            strokeWidth = 3f; strokeJoin = Paint.Join.ROUND
        }
        private val arrow = Path()
        override fun onDraw(canvas: Canvas) {
            val w = width.toFloat()
            arrow.reset()
            arrow.moveTo(1f, 1f)
            arrow.lineTo(1f, w * 0.72f)
            arrow.lineTo(w * 0.26f, w * 0.55f)
            arrow.lineTo(w * 0.42f, w * 0.88f)
            arrow.lineTo(w * 0.55f, w * 0.82f)
            arrow.lineTo(w * 0.40f, w * 0.50f)
            arrow.lineTo(w * 0.66f, w * 0.46f)
            arrow.close()
            canvas.drawPath(arrow, fill)
            canvas.drawPath(arrow, edge)
        }
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
            "tab" -> typeText("\t")
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
