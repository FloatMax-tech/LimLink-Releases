package com.limlink.app.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.limlink.app.R
import com.limlink.ui.theme.LocalLimLinkTheme

@Composable
fun CapsuleButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    primary: Boolean = false,
    destructive: Boolean = false,
    enabled: Boolean = true,
    testTag: String? = null,
    leading: (@Composable () -> Unit)? = null,
) {
    val theme = LocalLimLinkTheme.current
    val colors = if (primary) {
        ButtonDefaults.buttonColors(
            containerColor = theme.colors.buttonPrimaryBackground,
            contentColor = theme.colors.buttonPrimaryForeground,
            disabledContainerColor = theme.colors.buttonSecondaryBackground,
            disabledContentColor = theme.colors.buttonSecondaryForeground.copy(alpha = 0.6f),
        )
    } else {
        ButtonDefaults.buttonColors(
            containerColor = theme.colors.buttonSecondaryBackground,
            contentColor = if (destructive) {
                theme.colors.buttonDestructive
            } else {
                theme.colors.buttonSecondaryForeground
            },
        )
    }
    val border = if (primary && theme.colors.buttonPrimaryBorder != Color.Transparent) {
        BorderStroke(1.dp, theme.colors.buttonPrimaryBorder)
    } else {
        null
    }
    Button(
        onClick = onClick,
        modifier = modifier
            .heightIn(min = theme.metrics.controlHeight)
            .then(if (testTag != null) Modifier.testTag(testTag) else Modifier),
        enabled = enabled,
        shape = CircleShape,
        colors = colors,
        border = border,
    ) {
        if (leading != null) {
            leading()
            Spacer(Modifier.width(8.dp))
        }
        Text(text, fontFamily = FontFamily.Default)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScaffold(
    @StringRes titleId: Int,
    onBack: () -> Unit,
    backTestTag: String? = null,
    content: @Composable (androidx.compose.foundation.layout.PaddingValues) -> Unit,
) {
    Scaffold(
        contentWindowInsets = WindowInsets(0),
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = stringResource(titleId),
                        fontFamily = FontFamily.Default,
                        style = MaterialTheme.typography.titleLarge,
                    )
                },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = if (backTestTag != null) Modifier.testTag(backTestTag) else Modifier,
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.cd_back),
                        )
                    }
                },
            )
        },
        content = content,
    )
}
