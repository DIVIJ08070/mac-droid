package com.macdroid.app

import android.content.Context
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/** First-launch flag, stored separately from pairing preferences. */
object OnboardingPrefs {
    private const val PREFS = "macdroid_onboarding"
    private const val KEY_DONE = "done"

    fun isDone(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_DONE, false)

    fun setDone(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_DONE, true).apply()
    }
}

private data class OnboardPage(
    val kicker: String,
    val title: String,
    val body: String,
)

private val pages = listOf(
    OnboardPage(
        kicker = "01 · WELCOME",
        title = "Your Mac,\nin your pocket.",
        body = "Clipboard, files, audio and remote control between this phone " +
            "and your Mac — over Wi-Fi, hotspot, USB or Tailscale.\n\n" +
            "No cloud. No account.",
    ),
    OnboardPage(
        kicker = "02 · SETUP",
        title = "Install the\nMac app.",
        body = "Download Bifrost for macOS from the website and open it.\n\n" +
            "Then connect the two any way you like — same Wi-Fi, this phone's hotspot, " +
            "a USB cable, or Tailscale from anywhere.",
    ),
    OnboardPage(
        kicker = "03 · PAIRING",
        title = "Pair once,\nconnect forever.",
        body = "Your Mac appears in the list — tap Connect. Any connection works: " +
            "same Wi-Fi, this phone's hotspot, a USB cable, or Tailscale.\n\n" +
            "Check the 6-digit code matches on both screens, then hit Accept " +
            "on the Mac. You only do this once.",
    ),
    OnboardPage(
        kicker = "04 · EVERYDAY",
        title = "It just runs.",
        body = "MacDroid stays connected in the background behind a quiet " +
            "notification.\n\n" +
            "Send files to your Mac from any app — just use the share sheet.",
    ),
)

@Composable
fun OnboardingScreen(onDone: () -> Unit) {
    val pagerState = rememberPagerState(pageCount = { pages.size })
    val scope = rememberCoroutineScope()
    val isLast = pagerState.currentPage == pages.size - 1

    Column(
        Modifier
            .fillMaxSize()
            .background(MdBlack)
            .systemBarsPadding()
            .padding(horizontal = 28.dp, vertical = 16.dp)
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SectionLabel("MACDROID")
            Spacer(Modifier.weight(1f))
            if (!isLast) {
                TextButton(onClick = onDone) {
                    Text("Skip", color = MdWhite40, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                }
            }
        }

        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) { index ->
            OnboardPageView(pages[index])
        }

        PagerDots(
            count = pages.size,
            current = pagerState.currentPage,
            modifier = Modifier
                .align(Alignment.CenterHorizontally)
                .padding(bottom = 20.dp),
        )

        PrimaryPill(
            text = if (isLast) "Get started" else "Continue",
            modifier = Modifier
                .fillMaxWidth()
                .height(52.dp),
        ) {
            if (isLast) {
                onDone()
            } else {
                scope.launch { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
            }
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun OnboardPageView(page: OnboardPage) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.Center,
    ) {
        Entrance(0) { SectionLabel(page.kicker) }
        Spacer(Modifier.height(20.dp))
        Entrance(1) {
            Text(
                page.title,
                color = MdWhite,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Light,
                fontSize = 34.sp,
                lineHeight = 42.sp,
            )
        }
        Spacer(Modifier.height(20.dp))
        Entrance(2) {
            Text(
                page.body,
                color = MdWhite60,
                fontFamily = FontFamily.Monospace,
                fontSize = 14.sp,
                lineHeight = 22.sp,
            )
        }
    }
}

@Composable
private fun PagerDots(count: Int, current: Int, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        repeat(count) { i ->
            val active = i == current
            val width by animateDpAsState(if (active) 22.dp else 7.dp, tween(250), label = "dotW")
            val color by animateColorAsState(if (active) MdWhite else MdWhite40, tween(250), label = "dotC")
            Box(
                Modifier
                    .size(width = width, height = 7.dp)
                    .background(color, CircleShape)
            )
        }
    }
}
