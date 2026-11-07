package com.limlink.ui.dial

import android.animation.ValueAnimator
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.limlink.ui.theme.LocalLimLinkTheme

enum class DialPhase {
    ACTIVE,
    INDETERMINATE,
    PAUSED,
    COMPLETE,
    FAILED,
}

data class DialModel(
    val phase: DialPhase,
    val progress: Float,
    val directionLabel: String,
    val peerName: String,
    val centerPrimary: String,
    val percentLabel: String,
    val detailLabel: String,
    val contentDescription: String,
)

@Composable
fun ProgressDial(
    model: DialModel,
    modifier: Modifier = Modifier,
) {
    val theme = LocalLimLinkTheme.current
    val metrics = theme.metrics
    val wide = with(LocalDensity.current) {
        LocalWindowInfo.current.containerSize.width.toDp() >= metrics.tabletWidthDp.dp
    }
    val diameter = if (wide) metrics.dialDiameterTablet else metrics.dialDiameterPhone
    val lineWidth = metrics.dialLineWidth
    val animators = ValueAnimator.areAnimatorsEnabled()
    val animatedProgress by animateFloatAsState(
        targetValue = model.progress.coerceIn(0f, 1f),
        animationSpec = tween(durationMillis = if (animators) 300 else 0),
        label = "dial-progress",
    )
    val spin by rememberInfiniteTransition(label = "dial-spin").animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 1000, easing = LinearEasing)),
        label = "dial-spin-angle",
    )
    val progressColor = when (model.phase) {
        DialPhase.PAUSED -> theme.colors.dialPaused
        DialPhase.FAILED -> theme.colors.dialFailure
        else -> theme.colors.dialProgress
    }
    val trackColor = if (model.phase == DialPhase.PAUSED) {
        theme.colors.dialPaused.copy(alpha = 0.35f)
    } else {
        theme.colors.dialTrack
    }
    val showProgress = model.phase == DialPhase.ACTIVE ||
        model.phase == DialPhase.PAUSED ||
        model.phase == DialPhase.FAILED ||
        model.phase == DialPhase.COMPLETE
    val sweep = when (model.phase) {
        DialPhase.INDETERMINATE -> 90f
        DialPhase.COMPLETE -> 360f
        else -> 360f * animatedProgress
    }
    val start = when {
        model.phase == DialPhase.INDETERMINATE && animators -> metrics.dialStartAngle + spin
        else -> metrics.dialStartAngle
    }

    Column(
        modifier = modifier
            .testTag("progress_dial")
            .semantics(mergeDescendants = true) {
                contentDescription = model.contentDescription
                if (showProgress && model.phase != DialPhase.INDETERMINATE) {
                    progressBarRangeInfo = ProgressBarRangeInfo(model.progress.coerceIn(0f, 1f), 0f..1f)
                }
            },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(diameter)) {
            Canvas(Modifier.size(diameter)) {
                val stroke = Stroke(width = lineWidth.toPx(), cap = StrokeCap.Round)
                val inset = lineWidth.toPx() / 2f
                val arcSize = Size(size.width - lineWidth.toPx(), size.height - lineWidth.toPx())
                val topLeft = Offset(inset, inset)
                drawArc(
                    color = trackColor,
                    startAngle = 0f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = stroke,
                )
                if (model.phase == DialPhase.INDETERMINATE || sweep > 0f) {
                    drawArc(
                        color = progressColor,
                        startAngle = start,
                        sweepAngle = sweep,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = stroke,
                    )
                }
            }
            if (model.phase == DialPhase.COMPLETE || model.phase == DialPhase.FAILED) {
                Text(
                    text = if (model.phase == DialPhase.COMPLETE) "\u2713" else "!",
                    color = progressColor,
                    style = MaterialTheme.typography.displaySmall,
                    fontFamily = FontFamily.Default,
                )
            } else {
                Column(
                    modifier = Modifier.width(diameter - lineWidth * 2 - metrics.dialInset * 2),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (model.directionLabel.isNotEmpty()) {
                        Text(
                            text = model.directionLabel,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Default,
                            textAlign = TextAlign.Center,
                        )
                    }
                    Text(
                        text = model.peerName,
                        modifier = Modifier.padding(top = 4.dp),
                        color = MaterialTheme.colorScheme.onSurface,
                        style = MaterialTheme.typography.titleSmall,
                        fontFamily = FontFamily.Default,
                        fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center,
                        maxLines = 2,
                        overflow = TextOverflow.MiddleEllipsis,
                    )
                    Text(
                        text = model.centerPrimary,
                        modifier = Modifier.padding(top = 4.dp),
                        color = MaterialTheme.colorScheme.onSurface,
                        style = MaterialTheme.typography.titleLarge.copy(
                            fontFeatureSettings = "tnum",
                        ),
                        fontFamily = FontFamily.Default,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        if (model.percentLabel.isNotEmpty()) {
            Text(
                text = model.percentLabel,
                modifier = Modifier.padding(top = 16.dp),
                color = if (model.phase == DialPhase.PAUSED) {
                    theme.colors.dialPaused
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
                style = MaterialTheme.typography.displaySmall.copy(fontFeatureSettings = "tnum"),
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.Bold,
            )
        }
        if (model.detailLabel.isNotEmpty()) {
            Text(
                text = model.detailLabel,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp, start = 24.dp, end = 24.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"),
                fontFamily = FontFamily.Default,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
fun ThinProgressBar(
    progress: Float?,
    modifier: Modifier = Modifier,
) {
    val theme = LocalLimLinkTheme.current
    Canvas(
        modifier
            .fillMaxWidth()
            .height(4.dp),
    ) {
        val radius = 2.dp.toPx()
        val corners = androidx.compose.ui.geometry.CornerRadius(radius, radius)
        drawRoundRect(color = theme.colors.dialTrack, cornerRadius = corners)
        val fraction = progress?.coerceIn(0f, 1f)
        if (fraction != null && fraction > 0f) {
            drawRoundRect(
                color = theme.colors.dialProgress,
                size = Size(size.width * fraction, size.height),
                cornerRadius = corners,
            )
        }
    }
}
