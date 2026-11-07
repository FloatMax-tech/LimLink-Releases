package com.limlink.app.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.limlink.app.R
import com.limlink.ui.theme.LocalLimLinkTheme

/** Call only for a published receive or acknowledged send, never a byte-count threshold. */
@Composable fun VerifiedCompletion(modifier: Modifier = Modifier) {
    val reduced = !motionEnabled()
    var entered by remember { mutableStateOf(reduced) }
    LaunchedEffect(Unit) { entered = true }
    val progress by animateFloatAsState(if (entered) 1f else 0f, tween(if (reduced) 0 else 620, easing = FastOutSlowInEasing), label = "verified-completion")
    val ink = LocalLimLinkTheme.current.colors.signal
    val description = stringResource(R.string.preview_verified)
    Canvas(modifier.semantics { contentDescription = description }) {
        val side = size.minDimension
        val origin = Offset((size.width - side) / 2, (size.height - side) / 2)
        val stroke = side * 0.065f
        drawArc(ink.copy(alpha = 0.15f), 0f, 360f, false, origin + Offset(stroke, stroke), Size(side - 2 * stroke, side - 2 * stroke), style = Stroke(stroke))
        drawArc(ink, -90f, 360f * (progress / 0.65f).coerceIn(0f, 1f), false, origin + Offset(stroke, stroke), Size(side - 2 * stroke, side - 2 * stroke), style = Stroke(stroke, cap = StrokeCap.Round))
        val check = ((progress - 0.55f) / 0.45f).coerceIn(0f, 1f)
        val start = origin + Offset(side * 0.28f, side * 0.50f)
        val elbow = origin + Offset(side * 0.44f, side * 0.66f)
        val end = origin + Offset(side * 0.74f, side * 0.35f)
        val path = Path().apply {
            moveTo(start.x, start.y)
            if (check < 0.4f) { val p = start + (elbow - start) * (check / 0.4f); lineTo(p.x, p.y) }
            else { lineTo(elbow.x, elbow.y); val p = elbow + (end - elbow) * ((check - 0.4f) / 0.6f); lineTo(p.x, p.y) }
        }
        drawPath(path, ink, style = Stroke(stroke, cap = StrokeCap.Round))
    }
}
