package com.macdroid.app

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// MARK: - Design tokens (pure black / white / monospace)

val MdBlack = Color(0xFF000000)
val MdWhite = Color(0xFFFFFFFF)
val MdWhite60 = Color(0x99FFFFFF)
val MdWhite40 = Color(0x66FFFFFF)
val MdSurface = Color(0x14FFFFFF)      // white 8%
val MdSurfaceHi = Color(0x22FFFFFF)    // white 13%
val MdBorder = Color(0x1AFFFFFF)       // white 10%
val MdGreen = Color(0xFF34C759)
val MdAmber = Color(0xFFFF9F0A)

val CardShape = RoundedCornerShape(14.dp)
val PillShape = RoundedCornerShape(50)

private fun TextStyle.mono() = copy(fontFamily = FontFamily.Monospace)

private val base = Typography()
val MdTypography = Typography(
    displayLarge = base.displayLarge.mono(),
    displayMedium = base.displayMedium.mono(),
    displaySmall = base.displaySmall.mono(),
    headlineLarge = base.headlineLarge.mono().copy(fontWeight = FontWeight.Light),
    headlineMedium = base.headlineMedium.mono().copy(fontWeight = FontWeight.Light),
    headlineSmall = base.headlineSmall.mono().copy(fontWeight = FontWeight.Light),
    titleLarge = base.titleLarge.mono().copy(fontWeight = FontWeight.Light),
    titleMedium = base.titleMedium.mono(),
    titleSmall = base.titleSmall.mono(),
    bodyLarge = base.bodyLarge.mono(),
    bodyMedium = base.bodyMedium.mono(),
    bodySmall = base.bodySmall.mono(),
    labelLarge = base.labelLarge.mono(),
    labelMedium = base.labelMedium.mono(),
    labelSmall = base.labelSmall.mono(),
)

val MdColorScheme = darkColorScheme(
    primary = MdWhite,
    onPrimary = MdBlack,
    secondary = MdWhite,
    onSecondary = MdBlack,
    tertiary = MdWhite,
    onTertiary = MdBlack,
    background = MdBlack,
    onBackground = MdWhite,
    surface = MdBlack,
    onSurface = MdWhite,
    surfaceVariant = MdSurface,
    onSurfaceVariant = MdWhite60,
    outline = MdWhite40,
    outlineVariant = MdBorder,
)

@Composable
fun MacDroidTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = MdColorScheme,
        typography = MdTypography,
        content = content,
    )
}

// MARK: - Building blocks

/** Small uppercase section label with wide letter spacing. */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier, color: Color = MdWhite40) {
    Text(
        text.uppercase(),
        modifier = modifier,
        color = color,
        fontSize = 11.sp,
        letterSpacing = 3.sp,
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
    )
}

/** Translucent white card with a thin border. Tappable when [onClick] is given. */
@Composable
fun DarkCard(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    padding: Dp = 16.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    var m = modifier
        .fillMaxWidth()
        .clip(CardShape)
        .background(MdSurface)
        .border(1.dp, MdBorder, CardShape)
    if (onClick != null) m = m.clickable(onClick = onClick)
    Column(
        m.padding(padding),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        content = content,
    )
}

/** Primary action: white pill, black text. */
@Composable
fun PrimaryPill(
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        shape = PillShape,
        border = null,
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = MdWhite,
            contentColor = MdBlack,
            disabledContainerColor = MdSurfaceHi,
            disabledContentColor = MdWhite40,
        ),
    ) {
        Text(
            text,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            fontSize = 13.sp,
            maxLines = 1,
        )
    }
}

/** Secondary action: translucent white pill, white text, thin border. */
@Composable
fun GhostPill(
    text: String,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
    onClick: () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        shape = PillShape,
        border = BorderStroke(1.dp, MdBorder),
        contentPadding = if (compact) PaddingValues(horizontal = 6.dp, vertical = 8.dp)
        else ButtonDefaults.ContentPadding,
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = MdSurface,
            contentColor = MdWhite,
        ),
    ) {
        Text(
            text,
            fontFamily = FontFamily.Monospace,
            fontSize = if (compact) 11.sp else 13.sp,
            maxLines = 1,
        )
    }
}

/** Softly pulsing dot — used for "searching" / in-progress states. */
@Composable
fun PulsingDot(color: Color = MdWhite, size: Dp = 10.dp) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val alpha by transition.animateFloat(
        initialValue = 0.25f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(850), RepeatMode.Reverse),
        label = "alpha",
    )
    val scale by transition.animateFloat(
        initialValue = 0.8f,
        targetValue = 1.15f,
        animationSpec = infiniteRepeatable(tween(850), RepeatMode.Reverse),
        label = "scale",
    )
    Box(
        Modifier
            .size(size)
            .scale(scale)
            .background(color.copy(alpha = alpha), CircleShape)
    )
}

/** Static status dot. */
@Composable
fun StaticDot(color: Color, size: Dp = 10.dp) {
    Box(
        Modifier
            .size(size)
            .background(color, CircleShape)
    )
}

/** Gentle fade + slide-up entrance; stagger by [index]. */
@Composable
fun Entrance(index: Int = 0, content: @Composable () -> Unit) {
    val visibleState = remember { MutableTransitionState(false).apply { targetState = true } }
    AnimatedVisibility(
        visibleState = visibleState,
        enter = fadeIn(tween(durationMillis = 420, delayMillis = index * 70)) +
            slideInVertically(tween(durationMillis = 420, delayMillis = index * 70)) { it / 5 },
    ) { content() }
}
