package com.macdroid.app

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.Canvas
import kotlinx.coroutines.delay

/**
 * Launch splash: the Bifrost bridge-arc draws itself across the void, its two
 * endpoints (Mac ↔ phone) spark to life, and the wordmark rises in — then it
 * hands off to the app. Norse "Bifröst" = the rainbow bridge between worlds.
 */
@Composable
fun SplashScreen(onFinished: () -> Unit) {
    val accent = Color(0xFF7D6BFF)
    val arc = remember { Animatable(0f) }
    val endpoints = remember { Animatable(0f) }
    val wordmark = remember { Animatable(0f) }
    val glowT = rememberInfiniteTransition(label = "glow")
    val glow by glowT.animateFloat(
        initialValue = 0.08f, targetValue = 0.28f,
        animationSpec = infiniteRepeatable(tween(1300), RepeatMode.Reverse), label = "glowA"
    )

    LaunchedEffect(Unit) {
        arc.animateTo(1f, tween(1150, easing = LinearOutSlowInEasing))
        endpoints.animateTo(1f, tween(450))
    }
    LaunchedEffect(Unit) {
        delay(650)
        wordmark.animateTo(1f, tween(700))
    }
    val exit = remember { Animatable(1f) }
    LaunchedEffect(Unit) {
        delay(2050)
        exit.animateTo(0f, tween(550)) // cross-fade out, matching the Mac
        onFinished()
    }

    val bridge = listOf(
        Color(0xFF5B52FF), Color(0xFF8C66FF), Color(0xFF59BFFF), Color(0xFF4DE6CC)
    )

    Box(
        Modifier
            .fillMaxSize()
            .graphicsLayer { alpha = exit.value }
            .background(
                Brush.radialGradient(
                    colors = listOf(accent.copy(alpha = glow), Color.Black),
                    radius = 900f
                )
            )
            .background(Color.Black.copy(alpha = 0.25f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Canvas(Modifier.size(260.dp, 130.dp)) {
                val w = size.width; val h = size.height
                val path = Path().apply {
                    moveTo(0f, h)
                    quadraticBezierTo(w / 2f, -h * 0.15f, w, h)
                }
                val measure = android.graphics.PathMeasure(path.asAndroidPath(), false)
                val total = measure.length
                // Draw the arc up to `arc.value` by dashing everything past it away.
                drawPath(
                    path = path,
                    brush = Brush.horizontalGradient(bridge),
                    style = Stroke(
                        width = 10f, cap = StrokeCap.Round,
                        pathEffect = PathEffect.dashPathEffect(
                            floatArrayOf(total, total), (1f - arc.value) * total
                        )
                    )
                )
                if (endpoints.value > 0f) {
                    val a = endpoints.value
                    drawCircle(Color.White, radius = 9f * a, center = Offset(0f, h), alpha = a)
                    drawCircle(Color.White, radius = 9f * a, center = Offset(w, h), alpha = a)
                }
            }

            Spacer(Modifier.height(34.dp))

            Row {
                "BIFROST".forEachIndexed { i, c ->
                    val appear = (wordmark.value * 7f - i).coerceIn(0f, 1f)
                    Text(
                        text = c.toString(),
                        color = Color.White,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Light,
                        fontSize = 26.sp,
                        letterSpacing = 6.sp,
                        modifier = Modifier
                            .padding(start = 3.dp)
                            .graphicsLayer { alpha = appear; translationY = (1f - appear) * 16f }
                    )
                }
            }
        }
    }
}
