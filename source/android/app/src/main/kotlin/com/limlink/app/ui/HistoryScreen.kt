package com.limlink.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.limlink.app.R
import com.limlink.app.transfer.LanController
import com.limlink.app.preview.FilePreviewDialog
import com.limlink.app.preview.PreviewTarget
import com.limlink.app.preview.ReceivedFileActions

@Composable
fun HistoryScreen(modifier: Modifier = Modifier) {
    val history by LanController.history.collectAsState()
    var preview by remember { mutableStateOf<PreviewTarget?>(null) }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.title_history), style = MaterialTheme.typography.headlineMedium)
        if (history.isEmpty()) Text(stringResource(R.string.history_empty))
        history.forEach { item ->
            Card(Modifier.fillMaxWidth().then(if (item.receiving) Modifier.clickable { preview = LanController.receivedPreview(item) } else Modifier)) {
                Column(Modifier.padding(16.dp)) {
                    Text(stringResource(R.string.lan_file_size, item.fileName, item.size))
                    Text(stringResource(if (item.receiving) R.string.lan_from else R.string.lan_to, item.peer))
                    if (item.receiving) {
                        TextButton(onClick = { preview = LanController.receivedPreview(item) }) { Text(stringResource(R.string.preview_title)) }
                        ReceivedFileActions(item)
                    }
                }
            }
        }
        Text(stringResource(R.string.lan_history_session), style = MaterialTheme.typography.bodySmall)
    }
    preview?.let { target -> FilePreviewDialog(target) { preview = null } }
}
