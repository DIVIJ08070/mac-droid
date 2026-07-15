package com.macdroid.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@Composable
fun TouchpadPane(onBack: () -> Unit) {
    val haptics = LocalHapticFeedback.current
    var sensitivity by remember { mutableFloatStateOf(1f) }

    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            OutlinedButton(onClick = onBack) { Text("← Back") }
            Text("Mac Touchpad", style = MaterialTheme.typography.titleMedium)
            HelpButton(HelpContent.remote)
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .background(
                    MaterialTheme.colorScheme.surfaceVariant,
                    RoundedCornerShape(16.dp)
                )
                .pointerInput(sensitivity) {
                    trackpadGestures(sensitivity) {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    }
                },
            contentAlignment = Alignment.Center
        ) {
            Text(
                "1 finger: move • tap = click • double-tap & hold = drag\n" +
                    "2 fingers: scroll (with fling) • pinch = zoom • tap = right-click\n" +
                    "3 fingers: swipe ←/→ = switch Spaces • up = Mission Control\n" +
                    "down = App Exposé • tap = middle click\n" +
                    "4 fingers: up = Launchpad • down = show desktop",
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("Speed", style = MaterialTheme.typography.labelMedium)
            Slider(
                value = sensitivity,
                onValueChange = { sensitivity = it },
                valueRange = 0.4f..2.5f,
                modifier = Modifier.weight(1f)
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Button(
                onClick = { ConnectionManager.sendInput("c", button = "l") },
                modifier = Modifier.weight(2f)
            ) { Text("Left click") }
            Button(
                onClick = { ConnectionManager.sendInput("c", button = "r") },
                modifier = Modifier.weight(1f)
            ) { Text("Right click") }
        }
    }
}

/**
 * Full Mac-style trackpad state machine:
 * - 1 finger → cursor move; tap = click; double-tap & hold = drag
 * - 2 fingers → scroll (with momentum fling) or pinch-zoom; tap = right-click
 * - 3 fingers → swipe left/right = switch Spaces, up = Mission Control,
 *   down = App Exposé; tap = middle click
 * - 4 fingers → swipe up = Launchpad, down = show desktop
 */
private suspend fun PointerInputScope.trackpadGestures(
    sensitivity: Float,
    onDragStart: () -> Unit,
) {
    awaitPointerEventScope {
        var lastCentroid: Offset? = null
        var lastCount = 0
        var maxCount = 0
        var downTimeMs = 0L
        var lastTapAtMs = 0L
        var totalMovement = 0f
        var dragMode = false

        // two-finger mode: 0 = undecided, 1 = scroll, 2 = pinch
        var twoMode = 0
        var lastSpread = 0f
        var pinchAccum = 0f

        // 3-/4-finger swipe accumulation
        var swipeAccumX = 0f
        var swipeAccumY = 0f
        var verticalFired = false

        // fling velocity tracking
        var lastMoveTimeMs = 0L
        var velocityX = 0f
        var velocityY = 0f

        while (true) {
            val event = awaitPointerEvent()
            val pressed = event.changes.filter { it.pressed }
            val count = pressed.size
            val timeMs = event.changes.first().uptimeMillis

            when {
                count > 0 && lastCount == 0 -> { // gesture start
                    ConnectionManager.cancelScrollFling()
                    downTimeMs = timeMs
                    totalMovement = 0f
                    maxCount = count
                    lastCentroid = centroidOf(pressed)
                    lastSpread = spreadOf(pressed)
                    twoMode = 0
                    pinchAccum = 0f
                    swipeAccumX = 0f
                    swipeAccumY = 0f
                    verticalFired = false
                    velocityX = 0f
                    velocityY = 0f
                    lastMoveTimeMs = timeMs
                    if (timeMs - lastTapAtMs < 300) {
                        dragMode = true
                        ConnectionManager.sendInput("dd")
                        onDragStart()
                    }
                }

                count > 0 -> { // gesture continues
                    maxCount = maxOf(maxCount, count)
                    val centroid = centroidOf(pressed)
                    val spread = spreadOf(pressed)
                    val previous = lastCentroid

                    if (previous != null && count == lastCount) {
                        val delta = centroid - previous
                        totalMovement += delta.getDistance()
                        val dtMs = (timeMs - lastMoveTimeMs).coerceAtLeast(1L).toFloat()

                        when {
                            dragMode || (count == 1 && maxCount == 1) ->
                                ConnectionManager.sendInput(
                                    "m", delta.x * sensitivity, delta.y * sensitivity
                                )

                            count == 2 -> {
                                val spreadDelta = spread - lastSpread
                                if (twoMode == 0) {
                                    pinchAccum += spreadDelta
                                    if (kotlin.math.abs(pinchAccum) > 35f) {
                                        twoMode = 2
                                        pinchAccum = 0f
                                    } else if (totalMovement > 22f && kotlin.math.abs(pinchAccum) < 18f) {
                                        twoMode = 1
                                    }
                                }
                                if (twoMode == 1) {
                                    ConnectionManager.sendInput("sc", delta.x, delta.y)
                                    velocityX = delta.x / dtMs
                                    velocityY = delta.y / dtMs
                                } else if (twoMode == 2) {
                                    pinchAccum += spreadDelta
                                    while (pinchAccum > 90f) {
                                        ConnectionManager.sendInput("g", gesture = "pinchout")
                                        pinchAccum -= 90f
                                    }
                                    while (pinchAccum < -90f) {
                                        ConnectionManager.sendInput("g", gesture = "pinchin")
                                        pinchAccum += 90f
                                    }
                                }
                            }

                            count == 3 -> {
                                swipeAccumX += delta.x
                                swipeAccumY += delta.y
                                while (swipeAccumX < -130f) {
                                    ConnectionManager.sendInput("g", gesture = "3left")
                                    swipeAccumX += 130f
                                }
                                while (swipeAccumX > 130f) {
                                    ConnectionManager.sendInput("g", gesture = "3right")
                                    swipeAccumX -= 130f
                                }
                                if (!verticalFired &&
                                    kotlin.math.abs(swipeAccumY) > 80f &&
                                    kotlin.math.abs(swipeAccumY) > kotlin.math.abs(swipeAccumX)
                                ) {
                                    ConnectionManager.sendInput(
                                        "g", gesture = if (swipeAccumY < 0) "3up" else "3down"
                                    )
                                    verticalFired = true
                                }
                            }

                            count >= 4 -> {
                                swipeAccumY += delta.y
                                if (!verticalFired && kotlin.math.abs(swipeAccumY) > 80f) {
                                    ConnectionManager.sendInput(
                                        "g", gesture = if (swipeAccumY < 0) "4up" else "4down"
                                    )
                                    verticalFired = true
                                }
                            }
                        }
                    }
                    lastCentroid = centroid
                    lastSpread = spread
                    lastMoveTimeMs = timeMs
                }

                count == 0 && lastCount > 0 -> { // gesture end
                    if (dragMode) {
                        ConnectionManager.sendInput("du")
                        dragMode = false
                    } else if (timeMs - downTimeMs < 250 && totalMovement < 30f) {
                        val btn = when {
                            maxCount >= 3 -> "m"
                            maxCount == 2 -> "r"
                            else -> "l"
                        }
                        ConnectionManager.sendInput("c", button = btn)
                        if (maxCount == 1) lastTapAtMs = timeMs // only single taps arm drag
                    } else if (twoMode == 1 &&
                        (kotlin.math.abs(velocityX) > 0.35f || kotlin.math.abs(velocityY) > 0.35f)
                    ) {
                        ConnectionManager.startScrollFling(velocityX, velocityY)
                    }
                    lastCentroid = null
                    maxCount = 0
                    twoMode = 0
                }
            }

            lastCount = count
            event.changes.forEach { if (it.pressed || it.changedToUp()) it.consume() }
        }
    }
}

private fun centroidOf(changes: List<PointerInputChange>): Offset {
    var sum = Offset.Zero
    changes.forEach { sum += it.position }
    return sum / changes.size.toFloat()
}

/** Distance between the first two pointers — pinch detection. */
private fun spreadOf(changes: List<PointerInputChange>): Float {
    if (changes.size < 2) return 0f
    return (changes[0].position - changes[1].position).getDistance()
}
