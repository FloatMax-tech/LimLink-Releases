package com.limlink.app.ui

import android.content.pm.ApplicationInfo
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.activity.compose.rememberLauncherForActivityResult
import com.limlink.app.R
import com.limlink.app.ShellPrefs
import com.limlink.app.storage.LocationKind
import com.limlink.app.storage.OpenPersistableTree
import com.limlink.app.storage.SaveLocationRepository
import com.limlink.app.storage.SaveLocationStatus
import com.limlink.ui.theme.BrandTextRole
import com.limlink.ui.theme.BrandTitle
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    snackbarHostState: SnackbarHostState,
    onAbout: () -> Unit,
    onPrivacy: () -> Unit,
    onUsage: () -> Unit,
    onDemo: () -> Unit,
    onSample: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val deviceName by com.limlink.app.transfer.LanController.name.collectAsState()
    var editedName by androidx.compose.runtime.remember(deviceName) { androidx.compose.runtime.mutableStateOf(deviceName) }
    val repository = remember { SaveLocationRepository(context.applicationContext) }
    val status by repository.status.collectAsState(
        initial = SaveLocationStatus(LocationKind.DOWNLOADS, null, null),
    )
    val scope = rememberCoroutineScope()
    val permissionFailed = stringResource(R.string.folder_permission_failed)
    val picker = rememberLauncherForActivityResult(OpenPersistableTree()) { uri ->
        if (uri != null) {
            scope.launch {
                val saved = repository.setTree(uri)
                if (!saved) snackbarHostState.showSnackbar(permissionFailed)
            }
        }
    }
    val debuggable = remember {
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }
    val locationSubtitle = when (status.kind) {
        LocationKind.DOWNLOADS -> stringResource(R.string.location_downloads)
        LocationKind.TREE_OK -> status.treeLabel ?: stringResource(R.string.location_custom)
        LocationKind.TREE_UNAVAILABLE -> stringResource(R.string.location_unavailable)
    }
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        BrandTitle(
            textId = R.string.title_settings,
            role = BrandTextRole.LARGE_TITLE,
            modifier = Modifier.padding(bottom = 4.dp),
        )
        androidx.compose.material3.OutlinedTextField(value = editedName, onValueChange = { editedName = it.take(64) }, label = { Text(stringResource(R.string.lan_device_name)) }, singleLine = true)
        CapsuleButton(text = stringResource(R.string.lan_save_name), onClick = { com.limlink.app.transfer.LanController.rename(editedName) }, modifier = Modifier.fillMaxWidth())
        Text(
            text = stringResource(R.string.section_save_location),
            style = MaterialTheme.typography.titleMedium,
            fontFamily = FontFamily.Default,
        )
        Text(
            text = locationSubtitle,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = FontFamily.Default,
        )
        CapsuleButton(
            text = stringResource(
                if (status.kind == LocationKind.TREE_UNAVAILABLE) {
                    R.string.action_reselect_folder
                } else {
                    R.string.action_choose_folder
                },
            ),
            onClick = { picker.launch(null) },
            modifier = Modifier.fillMaxWidth(),
        )
        if (status.kind != LocationKind.DOWNLOADS) {
            CapsuleButton(
                text = stringResource(R.string.action_restore_downloads),
                onClick = { scope.launch { repository.setDownloads() } },
                modifier = Modifier.fillMaxWidth(),
            )
        }
        val autoPhotos by com.limlink.app.preview.PhotoLibrary.autoSave.collectAsState()
        DebugSwitch(title = stringResource(R.string.photo_auto_save), checked = autoPhotos,
            onCheckedChange = { com.limlink.app.preview.PhotoLibrary.setAutoSave(context, it) })
        Text(stringResource(R.string.photo_auto_save_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        BindingSettings()
        val language = com.limlink.app.AppLanguage.current(context)
        val languageLabel = com.limlink.app.AppLanguage.options.firstOrNull { it.tag == language }?.let { stringResource(it.label) } ?: language
        var choosingLanguage by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
        SettingsRow(
            title = stringResource(R.string.settings_language),
            subtitle = languageLabel,
            onClick = { choosingLanguage = true },
            testTag = "settings_language",
        )
        if (choosingLanguage) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { choosingLanguage = false },
                containerColor = MaterialTheme.colorScheme.surface,
                title = { Text(stringResource(R.string.settings_language)) },
                text = {
                    Column {
                        com.limlink.app.AppLanguage.options.forEach { option ->
                            fun choose() {
                                com.limlink.app.AppLanguage.set(context, option.tag)
                                choosingLanguage = false
                                (context as? android.app.Activity)?.recreate()
                            }
                            androidx.compose.foundation.layout.Row(
                                Modifier.fillMaxWidth().clickable(onClick = ::choose).padding(vertical = 12.dp),
                                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                            ) {
                                androidx.compose.material3.RadioButton(selected = option.tag == language, onClick = ::choose)
                                Text(stringResource(option.label), modifier = Modifier.padding(start = 8.dp))
                            }
                        }
                    }
                },
                confirmButton = {},
                dismissButton = { TextButton(onClick = { choosingLanguage = false }) { Text(stringResource(R.string.action_cancel)) } },
            )
        }
        if (debuggable) {
            Text(
                text = stringResource(R.string.section_debug),
                modifier = Modifier.padding(top = 8.dp),
                style = MaterialTheme.typography.titleMedium,
                fontFamily = FontFamily.Default,
            )
            CapsuleButton(
                text = stringResource(R.string.action_write_sample),
                onClick = onSample,
                modifier = Modifier.fillMaxWidth(),
                testTag = "settings_sample",
            )
            DebugSwitch(
                title = stringResource(R.string.debug_brand_enabled),
                checked = ShellPrefs.brandEnabled,
                onCheckedChange = { ShellPrefs.brandEnabled = it },
            )
            DebugSwitch(
                title = stringResource(R.string.debug_brand_inject),
                checked = ShellPrefs.standInFont,
                onCheckedChange = { ShellPrefs.standInFont = it },
            )
            Text(
                text = stringResource(brandStatus(ShellPrefs.brandEnabled, ShellPrefs.standInFont)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontFamily = FontFamily.Default,
            )
        }
        Text(
            text = stringResource(R.string.section_about),
            modifier = Modifier.padding(top = 8.dp),
            style = MaterialTheme.typography.titleMedium,
            fontFamily = FontFamily.Default,
        )
        SettingsRow(
            title = stringResource(R.string.section_about),
            subtitle = stringResource(R.string.action_diagnostics),
            onClick = onAbout,
            testTag = "settings_about",
        )
        UpdateSettings()
        SettingsRow(
            title = stringResource(R.string.action_privacy),
            onClick = onPrivacy,
            testTag = "settings_privacy",
        )
        SettingsRow(
            title = stringResource(R.string.usage_title),
            onClick = onUsage,
            testTag = "settings_usage",
        )
    }
}

@Composable
private fun DebugSwitch(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    androidx.compose.foundation.layout.Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Text(text = title, fontFamily = FontFamily.Default, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

private fun brandStatus(enabled: Boolean, injected: Boolean): Int {
    return when {
        !enabled -> R.string.debug_brand_off
        injected -> R.string.debug_brand_on_injected
        else -> R.string.debug_brand_on_system
    }
}
