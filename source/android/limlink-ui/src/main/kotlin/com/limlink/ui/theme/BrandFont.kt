package com.limlink.ui.theme

import androidx.annotation.StringRes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight

enum class BrandTextRole {
    BRAND_TITLE,
    LARGE_TITLE,
    INVITE_DIGITS,
}

enum class FontSource {
    SYSTEM,
    PROVIDED,
}

fun resolveBrandFont(
    enabled: Boolean,
    fontProvided: Boolean,
    role: BrandTextRole,
    appliesTo: Set<BrandTextRole>,
): FontSource {
    if (!enabled || !fontProvided || role !in appliesTo) return FontSource.SYSTEM
    return FontSource.PROVIDED
}

data class BrandFontSetting(
    val enabled: Boolean = true,
    val fontFamily: FontFamily? = null,
    val appliesTo: Set<BrandTextRole> = BrandTextRole.entries.toSet(),
) {
    fun familyFor(role: BrandTextRole): FontFamily {
        val source = resolveBrandFont(
            enabled = enabled,
            fontProvided = fontFamily != null,
            role = role,
            appliesTo = appliesTo,
        )
        return if (source == FontSource.PROVIDED) fontFamily ?: FontFamily.Default else FontFamily.Default
    }
}

val LocalBrandFont = staticCompositionLocalOf { BrandFontSetting() }

@Composable
fun BrandTitle(
    @StringRes textId: Int,
    modifier: Modifier = Modifier,
    role: BrandTextRole = BrandTextRole.BRAND_TITLE,
    style: TextStyle = MaterialTheme.typography.headlineLarge,
    color: Color = Color.Unspecified,
) {
    Text(
        text = stringResource(textId),
        modifier = modifier,
        color = color,
        style = style.merge(
            TextStyle(
                fontFamily = LocalBrandFont.current.familyFor(role),
                fontWeight = FontWeight.Bold,
            ),
        ),
    )
}
