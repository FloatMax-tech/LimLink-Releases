package com.limlink.app.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.limlink.app.R
import com.limlink.ui.theme.BrandTextRole
import com.limlink.ui.theme.BrandTitle
import com.limlink.ui.theme.LocalLimLinkTheme

@Composable
fun AboutScreen(
    padding: PaddingValues,
    versionName: String,
    onDiagnostics: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(padding)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        BrandTitle(textId = R.string.brand_name, role = BrandTextRole.BRAND_TITLE)
        Text(
            text = stringResource(R.string.about_version, versionName),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = FontFamily.Default,
        )
        SettingsRow(
            title = stringResource(R.string.action_diagnostics),
            onClick = onDiagnostics,
            testTag = "about_diagnostics",
        )
    }
}

@Composable
fun DiagnosticsScreen(padding: PaddingValues) {
    val available by com.limlink.app.transfer.LanController.available.collectAsState()
    val peers by com.limlink.app.transfer.LanController.peers.collectAsState()
    val state by com.limlink.app.transfer.LanController.state.collectAsState()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        SectionLabel(stringResource(R.string.diag_local))
        FactRow(stringResource(R.string.diag_endpoint), stringResource(if (available) R.string.lan_listening else R.string.diag_not_listening))
        val fingerprint by com.limlink.app.transfer.LanController.fingerprint.collectAsState()
        if (fingerprint.isNotEmpty()) FactRow(stringResource(R.string.diag_fingerprint), fingerprint)
        FactRow(stringResource(R.string.diag_protocol), stringResource(R.string.diag_protocol_value))
        FactRow(stringResource(R.string.diag_app), stringResource(R.string.diag_app_value))
        FactRow(stringResource(R.string.diag_last_error), state.error.ifBlank { stringResource(R.string.diag_no_error) })
        SectionLabel(stringResource(R.string.diag_devices))
        if (peers.isEmpty()) Text(stringResource(R.string.diag_no_devices))
        peers.forEach { peer -> FactRow(peer.name, "${peer.address.hostAddress}:${peer.port}") }
    }
}

@Composable
fun PrivacyScreen(padding: PaddingValues) {
    Column(
        Modifier
            .testTag("privacy.screen")
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(padding)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        PrivacyParagraph(stringResource(R.string.legal_operator))
        PrivacyParagraph(stringResource(R.string.privacy_lan))
        PrivacyParagraph(stringResource(R.string.privacy_collection))
        PrivacyParagraph(stringResource(R.string.privacy_name))
        PrivacyParagraph(stringResource(R.string.privacy_binding))
        PrivacyParagraph(stringResource(R.string.privacy_preview_photos))
        PrivacyParagraph(stringResource(R.string.privacy_updates))
        PrivacyParagraph(stringResource(R.string.privacy_contact))
        OnlineLegalLink(R.string.legal_online_privacy, stringResource(R.string.legal_privacy_url))
    }
}

@Composable
fun UsageScreen(padding: PaddingValues) {
    Column(
        Modifier
            .testTag("terms.usage")
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(padding)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            text = stringResource(R.string.legal_operator),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = FontFamily.Default,
        )
        Text(
            text = stringResource(R.string.usage_developer),
            modifier = Modifier.testTag("terms.developer"),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = FontFamily.Default,
        )
        UsageSection(R.string.usage_overview_title, R.string.usage_overview, "terms.overview")
        UsageSection(R.string.usage_sharing_title, R.string.usage_sharing, "terms.sharing")
        UsageSection(R.string.usage_transfer_title, R.string.usage_transfer, "terms.transfer")
        UsageSection(R.string.preview_title, R.string.usage_preview_photos, "terms.preview")
        UsageSection(R.string.usage_help_title, R.string.usage_help, "terms.help")
        Text(
            text = stringResource(R.string.usage_excerpt_notice),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = FontFamily.Default,
        )
        UsageSection(R.string.usage_liability_title, R.string.usage_liability_body, "terms.liability")
        UsageSection(R.string.usage_disclaimer_title, R.string.usage_disclaimer_body, "terms.disclaimer")
        Text(
            text = stringResource(R.string.usage_contact),
            modifier = Modifier.testTag("terms.email"),
            style = MaterialTheme.typography.bodyLarge,
            fontFamily = FontFamily.Default,
        )
        OnlineLegalLink(R.string.legal_online_terms, stringResource(R.string.legal_terms_url))
    }
}

@Composable
private fun OnlineLegalLink(@StringRes label: Int, url: String) {
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current
    val error = stringResource(R.string.legal_open_failed)
    TextButton(onClick = {
        try {
            uriHandler.openUri(url)
        } catch (_: Exception) {
            android.widget.Toast.makeText(context, error, android.widget.Toast.LENGTH_SHORT).show()
        }
    }) {
        Text(stringResource(label), fontFamily = FontFamily.Default)
    }
}

@Composable
private fun UsageSection(@StringRes title: Int, @StringRes body: Int, testTag: String) {
    Column(Modifier.testTag(testTag), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel(stringResource(title))
        PrivacyParagraph(stringResource(body))
    }
}

@Composable
fun InvitePlaceholderScreen(
    padding: PaddingValues,
    showing: Boolean,
) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(padding)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(
            text = stringResource(
                if (showing) R.string.invite_show_body else R.string.invite_enter_body,
            ),
            style = MaterialTheme.typography.bodyLarge,
            fontFamily = FontFamily.Default,
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        fontFamily = FontFamily.Default,
    )
}

@Composable
private fun FactRow(label: String, value: String) {
    Column {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = FontFamily.Default,
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyLarge,
            fontFamily = FontFamily.Default,
        )
    }
}

@Composable
private fun PrivacyParagraph(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodyLarge,
        fontFamily = FontFamily.Default,
    )
}

@Composable
fun SettingsRow(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    testTag: String? = null,
) {
    val theme = LocalLimLinkTheme.current
    Card(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .then(if (testTag != null) Modifier.testTag(testTag) else Modifier),
        shape = RoundedCornerShape(theme.metrics.cardRadius),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(text = title, fontFamily = FontFamily.Default, style = MaterialTheme.typography.titleMedium)
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    modifier = Modifier.padding(top = 4.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontFamily = FontFamily.Default,
                )
            }
        }
    }
}
