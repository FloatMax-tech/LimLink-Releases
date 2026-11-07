package com.limlink.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

data class LimLinkColors(
    val dialTrack: Color,
    val dialProgress: Color,
    val dialPaused: Color,
    val dialFailure: Color,
    val accent: Color,
    val accentText: Color,
    val buttonPrimaryBackground: Color,
    val buttonPrimaryForeground: Color,
    val buttonPrimaryBorder: Color,
    val buttonSecondaryBackground: Color,
    val buttonSecondaryForeground: Color,
    val buttonDestructive: Color,
    /** Only for live states: ready, in progress, delivered. */
    val signal: Color,
    val signalSoft: Color,
    val dangerSoft: Color,
)

data class LimLinkMetrics(
    val controlHeight: Dp = 46.dp,
    val cardRadius: Dp = 20.dp,
    val dialDiameterPhone: Dp = 200.dp,
    val dialDiameterTablet: Dp = 240.dp,
    val dialLineWidth: Dp = 14.dp,
    val dialInset: Dp = 12.dp,
    val dialStartAngle: Float = -90f,
    val tabletWidthDp: Int = 600,
)

data class LimLinkTheme(
    val colors: LimLinkColors,
    val metrics: LimLinkMetrics,
    val brandFont: BrandFontSetting,
)

val LocalLimLinkTheme = staticCompositionLocalOf<LimLinkTheme> {
    error("LimLinkTheme is not provided")
}

// Five-platform design: ink is black on light and white on dark; signal green marks live states.
private val AccentLight = Color.Black
private val AccentDark = Color.White
private val AccentTextLight = Color.Black
private val AccentTextDark = Color.White

private val LightColors = LimLinkColors(
    dialTrack = Color.Black.copy(alpha = 0.20f),
    dialProgress = AccentLight,
    dialPaused = Color(0xFF8E8E93),
    dialFailure = Color(0xFFFF3B30),
    accent = AccentLight,
    accentText = AccentTextLight,
    buttonPrimaryBackground = Color.Black,
    buttonPrimaryForeground = Color.White,
    buttonPrimaryBorder = Color.Transparent,
    buttonSecondaryBackground = Color.Black.copy(alpha = 0.12f),
    buttonSecondaryForeground = Color.Black,
    buttonDestructive = Color(0xFFFF3B30),
    signal = Color(0xFF14A37A),
    signalSoft = Color(0x1F1FBF8F),
    dangerSoft = Color(0x17FF3B30),
)

private val DarkColors = LimLinkColors(
    dialTrack = Color.White.copy(alpha = 0.36f),
    dialProgress = AccentDark,
    dialPaused = Color(0xFF98989D),
    dialFailure = Color(0xFFFF453A),
    accent = AccentDark,
    accentText = AccentTextDark,
    buttonPrimaryBackground = Color.White,
    buttonPrimaryForeground = Color.Black,
    buttonPrimaryBorder = Color.Transparent,
    buttonSecondaryBackground = Color.White.copy(alpha = 0.14f),
    buttonSecondaryForeground = Color.White,
    buttonDestructive = Color(0xFFFF453A),
    signal = Color(0xFF34E0B0),
    signalSoft = Color(0x2434E0B0),
    dangerSoft = Color(0x24FF453A),
)

@Composable
fun ProvideLimLinkTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    brandFont: BrandFontSetting = BrandFontSetting(),
    content: @Composable () -> Unit,
) {
    val colors = if (darkTheme) DarkColors else LightColors
    val scheme = if (darkTheme) {
        darkColorScheme(
            primary = AccentDark,
            onPrimary = Color.Black,
            background = Color.Black,
            surface = Color(0xFF1C1C1E),
            surfaceContainerLow = Color.Black,
            onSurface = Color.White,
            onSurfaceVariant = Color(0xFFAEAEB2),
            outline = Color(0xFF48484A),
        )
    } else {
        lightColorScheme(
            primary = AccentLight,
            onPrimary = Color.White,
            background = Color(0xFFF2F2F7),
            surface = Color.White,
            surfaceContainerLow = Color(0xFFF2F2F7),
            onSurface = Color.Black,
            onSurfaceVariant = Color(0xFF636366),
            outline = Color(0xFFC6C6C8),
        )
    }
    val theme = LimLinkTheme(
        colors = colors,
        metrics = LimLinkMetrics(),
        brandFont = brandFont,
    )
    CompositionLocalProvider(
        LocalLimLinkTheme provides theme,
        LocalBrandFont provides brandFont,
    ) {
        MaterialTheme(
            colorScheme = scheme,
            content = content,
        )
    }
}
