package com.limlink.app.ui
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.limlink.app.R
import com.limlink.app.BuildConfig
import com.limlink.kit.updates.*
import kotlinx.coroutines.*

private data class UpdateActions(val busy: Boolean, val check: () -> Unit)
private val LocalUpdates = staticCompositionLocalOf<UpdateActions> { error("UpdateHost missing") }

@Composable fun UpdateHost(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var update by remember { mutableStateOf<AvailableUpdate?>(null) }
    var message by remember { mutableStateOf<Int?>(null) }
    val active = remember { java.util.concurrent.atomic.AtomicReference<UpdateRequest?>(null) }
    DisposableEffect(Unit) { onDispose { active.getAndSet(null)?.cancel() } }
    val trigger: () -> Unit = {
        if (!busy) {
            busy = true
            val request = UpdateRequest()
            active.set(request)
            scope.launch {
                try {
                    update = withContext(Dispatchers.IO) { UpdateClient.check(BuildConfig.VERSION_NAME,request) }
                    if (update == null) message = R.string.updates_latest
                } catch (e: CancellationException) { throw e
                } catch (_: NoReleaseException) { message = R.string.updates_none
                } catch (_: Exception) { message = R.string.updates_failed
                } finally { active.compareAndSet(request,null); busy = false }
            }
        }
    }
    CompositionLocalProvider(LocalUpdates provides UpdateActions(busy, trigger)) { content() }
    message?.let { text ->
        AlertDialog(onDismissRequest={message=null},text={Text(stringResource(text))},confirmButton={
            TextButton(onClick={message=null}) { Text(stringResource(R.string.action_cancel)) }
        })
    }
    update?.let { release ->
        AlertDialog(onDismissRequest={update=null},title={Text(stringResource(R.string.updates_available)+" · "+release.version)},
            text={ Column(Modifier.heightIn(max=320.dp).verticalScroll(rememberScrollState())) {
                if (release.notes.isNotEmpty()) Text(release.notes)
                Text(stringResource(R.string.updates_install_hint))
            } },
            confirmButton={TextButton(onClick={
                try { context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(release.url))) }
                catch (_: android.content.ActivityNotFoundException) { }
                update=null
            }) {Text(stringResource(R.string.updates_download))}},
            dismissButton={TextButton(onClick={update=null}) {Text(stringResource(R.string.action_cancel))}})
    }
}
@Composable fun UpdateSettings() {
    val actions = LocalUpdates.current
    TextButton(enabled=!actions.busy,onClick=actions.check) {
        Text(stringResource(if(actions.busy) R.string.updates_checking else R.string.updates_check))
    }
    Text(stringResource(R.string.updates_disclosure),style=MaterialTheme.typography.bodySmall)
}
