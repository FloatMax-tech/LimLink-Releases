package com.limlink.app.preview

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.limlink.app.R
import com.limlink.app.transfer.HistoryEntry
import com.limlink.app.transfer.LanController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable fun ReceivedFileActions(entry: HistoryEntry) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val image = PreviewPolicy.kind(entry.fileName, entry.mime) == PreviewKind.IMAGE
    var busy by remember(entry.locator) { mutableStateOf(false) }
    val failed = stringResource(R.string.preview_action_failed)
    Column {
        if (image) Text(stringResource(when (entry.photoState) {
            PhotoState.SAVING -> R.string.photo_saving
            PhotoState.SAVED -> R.string.photo_saved
            PhotoState.FAILED -> R.string.photo_failed
            else -> R.string.photo_disabled
        }), style = MaterialTheme.typography.bodySmall, color = if (entry.photoState == PhotoState.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = {
                val target = LanController.receivedPreview(entry) ?: return@TextButton
                busy = true
                scope.launch {
                    try {
                        if (image) FileActions.gallery(context, LanController.exportImage(target)) else FileActions.location(context, target)
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { android.widget.Toast.makeText(context, failed, android.widget.Toast.LENGTH_LONG).show() }
                    finally { busy = false }
                }
            }, enabled = !busy && entry.photoState != PhotoState.SAVING) {
                Text(stringResource(if (image) R.string.preview_gallery else R.string.preview_location))
            }
            if (entry.photoState == PhotoState.FAILED) TextButton(onClick = { LanController.retryGallery(entry) }) { Text(stringResource(R.string.photo_retry)) }
        }
    }
}
