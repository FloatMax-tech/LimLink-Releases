package com.limlink.app.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.limlink.ui.theme.LocalLimLinkTheme

/**
 * The shared LimLink progress ring. A spinning quarter arc means waiting; values glide to their
 * target, and [drawIn] sweeps from empty when the ring first appears.
 */
@Composable
fun Ring(
    progress: Float,
    modifier: Modifier = Modifier,
    thickness: Dp = 8.dp,
    color: Color = MaterialTheme.colorScheme.onSurface,
    track: Color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f),
    spinning: Boolean = false,
    drawIn: Boolean = false,
) {
    val enabled = motionEnabled()
    val target = progress.coerceIn(0f, 1f)
    val shown = remember { Animatable(if (drawIn && enabled) 0f else target) }
    LaunchedEffect(target) {
        when {
            !enabled || target < shown.value - 0.25f -> shown.snapTo(target)
            drawIn && shown.value == 0f -> shown.animateTo(target, tween(900, easing = ExpoOut))
            else -> shown.animateTo(target, tween(380, easing = ExpoOut))
        }
    }
    // Animated values are read inside draw/layer lambdas so frames redraw without recomposing.
    val rotation = if (spinning && enabled) {
        rememberInfiniteTransition(label = "ring-spin").animateFloat(
            0f, 360f, infiniteRepeatable(tween(1200, easing = LinearEasing)), label = "ring-angle",
        )
    } else null
    Canvas(modifier.graphicsLayer { rotationZ = rotation?.value ?: 0f }) {
        val stroke = thickness.toPx()
        val inset = stroke / 2
        val arcSize = Size(size.minDimension - stroke, size.minDimension - stroke)
        val topLeft = Offset((size.width - arcSize.width) / 2, (size.height - arcSize.height) / 2)
        if (track.alpha > 0f) drawCircle(track, radius = size.minDimension / 2 - inset, style = Stroke(stroke))
        val sweep = if (spinning) 90f else shown.value * 360f
        if (sweep > 0.3f) drawArc(color, -90f, sweep, false, topLeft, arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
    }
}

/** One-shot ripple behind the delivered check: scale 0.92 → 1.4 while fading out. */
@Composable
fun BurstRing(color: Color, modifier: Modifier = Modifier, delayMillis: Int = 520) {
    val enabled = motionEnabled()
    val progress = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        if (!enabled) return@LaunchedEffect
        kotlinx.coroutines.delay(delayMillis.toLong())
        progress.animateTo(1f, tween(900, easing = ExpoOut))
    }
    Canvas(modifier) {
        val p = progress.value
        if (p <= 0f || p >= 1f) return@Canvas
        drawCircle(color.copy(alpha = 0.6f * (1f - p)), radius = size.minDimension / 2 * (0.92f + 0.48f * p), style = Stroke(2.dp.toPx()))
    }
}

enum class StepState { Todo, Now, Done }

@Composable
fun StepRow(labels: List<String>, current: Int, modifier: Modifier = Modifier) {
    val theme = LocalLimLinkTheme.current
    val ink = MaterialTheme.colorScheme.onSurface
    val sub = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
        labels.forEachIndexed { index, label ->
            val state = when { index < current -> StepState.Done; index == current -> StepState.Now; else -> StepState.Todo }
            Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
                if (state == StepState.Now) Halo(theme.colors.signal)
                Canvas(Modifier.fillMaxSize()) {
                    when (state) {
                        StepState.Done -> {
                            drawCircle(ink)
                            val check = Path().apply { moveTo(size.width * .3f, size.height * .52f); lineTo(size.width * .45f, size.height * .66f); lineTo(size.width * .72f, size.height * .36f) }
                            drawPath(check, if (ink.luminance() > 0.5f) Color.Black else Color.White, style = Stroke(1.6.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                        }
                        StepState.Now -> { drawCircle(theme.colors.signal, style = Stroke(1.5.dp.toPx())); drawCircle(theme.colors.signal, radius = 3.dp.toPx()) }
                        StepState.Todo -> drawCircle(sub.copy(alpha = 0.6f), radius = size.minDimension / 2 - 0.75.dp.toPx(), style = Stroke(1.5.dp.toPx()))
                    }
                }
            }
            Spacer(Modifier.width(5.dp))
            Text(
                label, fontSize = 12.sp,
                color = when (state) { StepState.Done -> ink; StepState.Now -> theme.colors.signal; StepState.Todo -> sub },
                fontWeight = if (state == StepState.Now) FontWeight.SemiBold else FontWeight.Normal,
            )
            if (index < labels.lastIndex) Box(Modifier.padding(horizontal = 7.dp).size(14.dp, 1.dp).background(sub.copy(alpha = 0.5f)))
        }
    }
}

internal fun Color.luminance(): Float = 0.2126f * red + 0.7152f * green + 0.0722f * blue

@Composable
private fun Halo(color: Color) {
    if (!motionEnabled()) return
    val t = rememberInfiniteTransition(label = "halo").animateFloat(0f, 1f, infiniteRepeatable(tween(1400), RepeatMode.Restart), label = "halo-t")
    Canvas(Modifier.size(16.dp)) {
        val p = t.value
        drawCircle(color.copy(alpha = 0.7f * (1f - p)), radius = size.minDimension / 2 * (1f + 0.9f * p), style = Stroke(1.5.dp.toPx()))
    }
}

/** Concentric rings with two signal pulses travelling outward; the LimLink mark sits in the middle. */
@Composable
fun Radar(active: Boolean, modifier: Modifier = Modifier) {
    val theme = LocalLimLinkTheme.current
    val line = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    val animate = active && motionEnabled()
    val pulse = if (animate) {
        rememberInfiniteTransition(label = "radar").animateFloat(0f, 1f, infiniteRepeatable(tween(3000, easing = LinearEasing)), label = "radar-t")
    } else null
    Box(modifier.size(170.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val t = pulse?.value ?: -1f
            val r = size.minDimension / 2
            drawCircle(line, radius = r * 0.7f, style = Stroke(1.dp.toPx()))
            drawCircle(line, radius = r - 1.dp.toPx(), style = Stroke(1.dp.toPx()))
            if (t >= 0f) for (phase in listOf(t, (t + 0.5f) % 1f)) {
                val eased = ExpoOut.transform(phase)
                drawCircle(theme.colors.signal.copy(alpha = 0.7f * (1f - phase)), radius = r * (0.4f + 0.6f * eased), style = Stroke(1.5.dp.toPx()))
            }
        }
        Box(
            Modifier.size(64.dp).background(MaterialTheme.colorScheme.surface, CircleShape)
                .border(1.dp, line, CircleShape),
            contentAlignment = Alignment.Center,
        ) { LogoMark(Modifier.size(30.dp)) }
    }
}

/** Brand mark from tools/branding: ring radii 39 and 27 on a 108 unit black tile. */
@Composable
fun LogoMark(modifier: Modifier = Modifier) {
    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    Canvas(modifier) {
        val s = size.minDimension / 108f
        drawRoundRect(Color.Black, cornerRadius = CornerRadius(24 * s))
        if (dark) drawRoundRect(Color.White.copy(alpha = 0.25f), cornerRadius = CornerRadius(24 * s), style = Stroke(2 * s))
        drawCircle(Color.White, radius = 33 * s, style = Stroke(12 * s))
    }
}

/** File card illustration: dashed slowly turning ring when empty, a drawn-in ink ring once selected. */
@Composable
fun FileArt(selected: Boolean, modifier: Modifier = Modifier) {
    val ink = MaterialTheme.colorScheme.onSurface
    val faint = ink.copy(alpha = 0.08f)
    val dash = ink.copy(alpha = 0.28f)
    val enabled = motionEnabled()
    val turn = if (!selected && enabled) {
        rememberInfiniteTransition(label = "dash").animateFloat(0f, 360f, infiniteRepeatable(tween(40000, easing = LinearEasing)), label = "dash-angle")
    } else null
    Box(modifier.size(144.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            drawCircle(faint, radius = size.minDimension / 2 - 1.dp.toPx(), style = Stroke(1.5.dp.toPx()))
            if (!selected) rotate(turn?.value ?: 0f) {
                drawCircle(dash, radius = size.minDimension * 0.36f, style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 6.dp.toPx()))))
            }
        }
        if (selected) Ring(1f, Modifier.size(104.dp), thickness = 10.dp, color = ink, track = faint, drawIn = true)
        Canvas(Modifier.size(144.dp).appear(Appear.Pop, if (selected) 160 else 0)) { drawDocument(ink, selected) }
    }
}

private fun DrawScope.drawDocument(ink: Color, selected: Boolean) {
    val u = size.minDimension / 144f
    val body = Path().apply { moveTo(58 * u, 50 * u); lineTo(74 * u, 50 * u); lineTo(86 * u, 62 * u); lineTo(86 * u, 94 * u); lineTo(58 * u, 94 * u); close() }
    if (selected) drawPath(body, ink.copy(alpha = 0.06f))
    val stroke = Stroke(2.2f * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
    drawPath(body, ink, style = stroke)
    drawPath(Path().apply { moveTo(74 * u, 50 * u); lineTo(74 * u, 62 * u); lineTo(86 * u, 62 * u) }, ink, style = stroke)
    if (selected) {
        listOf(72f to 80f, 79f to 80f, 86f to 73f).forEach { (y, end) -> drawLine(ink, Offset(64 * u, y * u), Offset(end * u, y * u), 2f * u, StrokeCap.Round) }
    } else {
        drawCircle(ink, radius = 9 * u, center = Offset(84 * u, 88 * u))
        val plus = if (ink.luminance() > 0.5f) Color.Black else Color.White
        drawLine(plus, Offset(84 * u, 84 * u), Offset(84 * u, 92 * u), 2f * u, StrokeCap.Round)
        drawLine(plus, Offset(80 * u, 88 * u), Offset(88 * u, 88 * u), 2f * u, StrokeCap.Round)
    }
}

/** Outline device glyphs; Material's core icon set has no phone/tablet/laptop/desktop shapes. */
@Composable
fun DeviceGlyph(type: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurface) {
    Canvas(modifier.size(36.dp)) {
        val u = size.minDimension / 24f
        val stroke = Stroke(1.7f * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
        fun rect(x: Float, y: Float, w: Float, h: Float, r: Float) = drawRoundRect(color, Offset(x * u, y * u), Size(w * u, h * u), CornerRadius(r * u), style = stroke)
        fun line(x1: Float, y1: Float, x2: Float, y2: Float) = drawLine(color, Offset(x1 * u, y1 * u), Offset(x2 * u, y2 * u), 1.7f * u, StrokeCap.Round)
        when (type) {
            "mac" -> { rect(4.5f, 5f, 15f, 10.5f, 1.5f); line(2f, 19f, 22f, 19f) }
            "windows" -> { rect(3f, 4f, 18f, 12f, 1.8f); line(9f, 20f, 15f, 20f); line(12f, 16f, 12f, 20f) }
            "ipad" -> { rect(4.5f, 2.5f, 15f, 19f, 2.5f); line(11f, 18.5f, 13f, 18.5f) }
            else -> { rect(7f, 2.5f, 10f, 19f, 2.5f); line(11f, 18.5f, 13f, 18.5f) }
        }
    }
}

@Composable
fun FileBadge(modifier: Modifier = Modifier, background: Color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f), content: @Composable () -> Unit) {
    Box(modifier.size(40.dp).background(background, RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) { content() }
}

@Composable
fun DocGlyph(modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurface, arrow: Int = 0) {
    Canvas(modifier.size(22.dp)) {
        val u = size.minDimension / 24f
        val stroke = Stroke(1.7f * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
        if (arrow == 0) {
            drawPath(Path().apply { moveTo(7 * u, 3 * u); lineTo(14 * u, 3 * u); lineTo(19 * u, 8 * u); lineTo(19 * u, 21 * u); lineTo(7 * u, 21 * u); close() }, color, style = stroke)
            drawPath(Path().apply { moveTo(14 * u, 3 * u); lineTo(14 * u, 8 * u); lineTo(19 * u, 8 * u) }, color, style = stroke)
        } else {
            // arrow > 0: received (down), arrow < 0: sent (up)
            val down = arrow > 0
            drawLine(color, Offset(12 * u, 4 * u), Offset(12 * u, 18 * u), 1.7f * u, StrokeCap.Round)
            val tipY = if (down) 18f else 4f
            val wingY = if (down) 12f else 10f
            drawPath(Path().apply { moveTo(6 * u, wingY * u); lineTo(12 * u, tipY * u); lineTo(18 * u, wingY * u) }, color, style = stroke)
            drawLine(color, Offset(5 * u, 21 * u), Offset(19 * u, 21 * u), 1.7f * u, StrokeCap.Round)
        }
    }
}
