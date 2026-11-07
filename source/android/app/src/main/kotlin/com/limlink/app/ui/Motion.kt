package com.limlink.app.ui

import android.animation.ValueAnimator
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/** Matches the Windows client: exponential ease-out for entrances and progress. */
val ExpoOut = CubicBezierEasing(0.16f, 1f, 0.3f, 1f)

/** Honors Settings > Accessibility > Remove animations (animator duration scale 0). */
@Composable
fun motionEnabled(): Boolean = remember { ValueAnimator.areAnimatorsEnabled() }

enum class Appear { Rise, Drop, Pop, Fade }

/** Entrance motion played once when the element enters composition. Stagger lists with [delayMillis]. */
fun Modifier.appear(kind: Appear = Appear.Rise, delayMillis: Int = 0): Modifier = composed {
    val enabled = motionEnabled()
    val progress = remember { Animatable(if (enabled) 0f else 1f) }
    LaunchedEffect(Unit) {
        if (!enabled) return@LaunchedEffect
        delay(delayMillis.toLong())
        if (kind == Appear.Pop) progress.animateTo(1f, spring(dampingRatio = 0.55f, stiffness = 420f))
        else progress.animateTo(1f, tween(520, easing = ExpoOut))
    }
    graphicsLayer {
        val p = progress.value
        alpha = (p * 1.6f).coerceIn(0f, 1f)
        when (kind) {
            Appear.Rise -> translationY = (1f - p) * 14.dp.toPx()
            Appear.Drop -> translationY = -(1f - p) * 10.dp.toPx()
            Appear.Pop -> { scaleX = 0.9f + 0.1f * p; scaleY = 0.9f + 0.1f * p }
            Appear.Fade -> Unit
        }
    }
}

/** Shrinks to 0.955 while pressed and springs back on release. */
fun Modifier.pressScale(interaction: InteractionSource): Modifier = composed {
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.955f else 1f,
        animationSpec = if (pressed) tween(90) else spring(dampingRatio = 0.42f, stiffness = Spring.StiffnessMedium),
        label = "press",
    )
    graphicsLayer { scaleX = scale; scaleY = scale }
}

/** Horizontal shake for failures, replayed whenever [key] changes. */
fun Modifier.shake(key: Any?, delayMillis: Int = 300): Modifier = composed {
    val enabled = motionEnabled()
    val offset = remember { Animatable(0f) }
    LaunchedEffect(key) {
        if (!enabled) return@LaunchedEffect
        delay(delayMillis.toLong())
        offset.animateTo(0f, keyframes {
            durationMillis = 390
            -9f at 65; 8f at 130; -6f at 195; 4f at 260; -2f at 325; 0f at 390
        })
    }
    graphicsLayer { translationX = offset.value.dp.toPx() }
}
