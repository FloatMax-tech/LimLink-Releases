package com.limlink.app.preview

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.pdf.PdfRenderer
import android.media.MediaPlayer
import android.os.ParcelFileDescriptor
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.limlink.app.R
import com.limlink.app.transfer.LanController
import java.io.Closeable
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** All rendering stays offline. Unsupported types require an explicit open-with action. */
@Composable
fun FilePreviewDialog(target: PreviewTarget, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var actionError by remember(target) { mutableStateOf(false) }
    var actionBusy by remember(target) { mutableStateOf(false) }
    DisposableEffect(target) { onDispose { target.close() } }
    fun action(block: suspend () -> Unit) {
        if (actionBusy) return
        actionBusy = true
        scope.launch {
            try { block(); actionError = false }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { actionError = true }
            finally { actionBusy = false }
        }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(target.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, maxLines = 2)
                    TextButton(onClick = onDismiss) { Text(stringResource(R.string.preview_close)) }
                }
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    when (target.kind) {
                        PreviewKind.IMAGE -> ImagePreview(target)
                        PreviewKind.PDF -> PdfPreview(target)
                        PreviewKind.VIDEO -> VideoPreview(target)
                        PreviewKind.AUDIO -> AudioPreview(target)
                        PreviewKind.TEXT -> TextPreview(target)
                        PreviewKind.UNSUPPORTED -> Text(stringResource(R.string.preview_unsupported))
                    }
                }
                if (actionError) Text(stringResource(R.string.preview_action_failed), color = MaterialTheme.colorScheme.error)
                if (actionBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { action { FileActions.openWith(context, target) } }, enabled = !actionBusy, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.preview_open_with)) }
                    OutlinedButton(onClick = { action { FileActions.share(context, target) } }, enabled = !actionBusy, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.preview_share)) }
                }
                OutlinedButton(onClick = { action {
                    if (target.kind == PreviewKind.IMAGE) {
                        val gallery = if (target.received) LanController.exportImage(target) else target.originalLocator
                        if (gallery != null) FileActions.gallery(context, gallery) else error("No original image location")
                    } else FileActions.location(context, target)
                } }, enabled = !actionBusy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(if (target.kind == PreviewKind.IMAGE) R.string.preview_gallery else R.string.preview_location))
                }
                if (target.kind != PreviewKind.IMAGE) Text(stringResource(R.string.preview_location_hint), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable private fun FailedPreview() { Text(stringResource(R.string.preview_unavailable)) }
@Composable private fun LoadingPreview() { CircularProgressIndicator() }

@Composable private fun ImagePreview(target: PreviewTarget) {
    val context = LocalContext.current
    var bitmap by remember(target) { mutableStateOf<Bitmap?>(null) }
    var failed by remember(target) { mutableStateOf(false) }
    LaunchedEffect(target) {
        try {
            bitmap = withContext(Dispatchers.IO) {
                val source = if (target.uri.scheme == "file") ImageDecoder.createSource(File(requireNotNull(target.uri.path))) else ImageDecoder.createSource(context.contentResolver, target.uri)
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    val (w, h) = PreviewPolicy.renderSize(info.size.width, info.size.height)
                    decoder.setTargetSize(w, h)
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }.also { decoded -> try { ensureActive() } catch (error: CancellationException) { decoded.recycle(); throw error } }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { failed = true }
    }
    when { failed -> FailedPreview(); bitmap != null -> Image(requireNotNull(bitmap).asImageBitmap(), target.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit); else -> LoadingPreview() }
}

@Composable private fun TextPreview(target: PreviewTarget) {
    val context = LocalContext.current
    var content by remember(target) { mutableStateOf<PreviewText?>(null) }
    var failed by remember(target) { mutableStateOf(false) }
    LaunchedEffect(target) {
        try { content = withContext(Dispatchers.IO) { target.open(context).use { PreviewPolicy.readText(it) } } }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { failed = true }
    }
    when {
        failed -> FailedPreview()
        content != null -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (content!!.truncated) Text(stringResource(R.string.preview_text_truncated), color = MaterialTheme.colorScheme.primary)
            SelectionContainer { Text(content!!.text, style = MaterialTheme.typography.bodyMedium) }
        }
        else -> LoadingPreview()
    }
}

private class PdfSession(renderer: PdfRenderer, temporary: File?) : Closeable {
    val pageCount = renderer.pageCount
    private class Resource(val renderer: PdfRenderer, private val temporary: File?) : Closeable {
        override fun close() { try { renderer.close() } finally { temporary?.delete() } }
    }
    private val owner = PreviewResourceOwner(Resource(renderer, temporary))
    fun render(index: Int): Bitmap = owner.use { resource ->
        resource.renderer.openPage(index).use { page ->
            val (w, h) = PreviewPolicy.renderSize(
                (page.width.toLong() * 2).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                (page.height.toLong() * 2).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { bitmap ->
                bitmap.eraseColor(android.graphics.Color.WHITE)
                try { page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY) }
                catch (error: Exception) { bitmap.recycle(); throw error }
            }
        }
    }
    override fun close() { owner.close() }
}

@Composable private fun PdfPreview(target: PreviewTarget) {
    val context = LocalContext.current
    var session by remember(target) { mutableStateOf<PdfSession?>(null) }
    var page by remember(target) { mutableIntStateOf(0) }
    var bitmap by remember(target) { mutableStateOf<Bitmap?>(null) }
    var failed by remember(target) { mutableStateOf(false) }
    LaunchedEffect(target) {
        var opened: PdfSession? = null
        try {
            withContext(Dispatchers.IO) {
                var temporary: File? = null
                var descriptor: ParcelFileDescriptor? = null
                try {
                    val file = if (target.uri.scheme == "file") File(requireNotNull(target.uri.path)) else {
                        check(target.size <= 512L * 1024 * 1024)
                        File.createTempFile("preview-", ".pdf", context.cacheDir).also { copy ->
                            temporary = copy
                            target.open(context).use { input -> copy.outputStream().use { output ->
                                val buffer = ByteArray(64 * 1024); var count = 0L
                                while (true) { ensureActive(); val n = input.read(buffer); if (n < 0) break; count += n; check(count <= 512L * 1024 * 1024); output.write(buffer, 0, n) }
                            } }
                        }
                    }
                    descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                    opened = PdfSession(PdfRenderer(requireNotNull(descriptor)), temporary)
                    descriptor = null
                    ensureActive()
                } catch (error: Exception) { descriptor?.close(); opened?.close(); temporary?.delete(); throw error }
            }
            session = opened
        } catch (cancelled: CancellationException) { opened?.close(); throw cancelled }
        catch (_: Exception) { opened?.close(); failed = true }
    }
    DisposableEffect(session) { val active = session; onDispose { active?.close() } }
    LaunchedEffect(session, page) {
        val active = session ?: return@LaunchedEffect
        try { bitmap = withContext(Dispatchers.IO) { active.render(page).also { decoded -> try { ensureActive() } catch (error: CancellationException) { decoded.recycle(); throw error } } } }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { failed = true }
    }
    if (failed) FailedPreview()
    else Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            if (bitmap == null) LoadingPreview() else Image(bitmap!!.asImageBitmap(), target.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
        session?.let { active ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TextButton(onClick = { page-- }, enabled = page > 0) { Text(stringResource(R.string.preview_previous)) }
                Text(stringResource(R.string.preview_page, page + 1, active.pageCount))
                TextButton(onClick = { page++ }, enabled = page + 1 < active.pageCount) { Text(stringResource(R.string.preview_next)) }
            }
        }
    }
}

@Composable private fun VideoPreview(target: PreviewTarget) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var failed by remember(target) { mutableStateOf(false) }
    val video = remember(target) { VideoView(context) }
    DisposableEffect(video, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) video.pause() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); video.stopPlayback() }
    }
    if (failed) FailedPreview() else Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        AndroidView(factory = {
            video.apply {
                setMediaController(MediaController(context).also { it.setAnchorView(this) })
                setOnErrorListener { _, _, _ -> failed = true; true }
                setOnPreparedListener { seekTo(1) }
                setVideoURI(target.uri)
            }
        }, modifier = Modifier.fillMaxWidth().weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TextButton(onClick = { runCatching { video.start() }.onFailure { failed = true } }) { Text(stringResource(R.string.preview_play)) }
            TextButton(onClick = { runCatching { video.pause() }.onFailure { failed = true } }) { Text(stringResource(R.string.preview_pause)) }
        }
    }
}

@Composable private fun AudioPreview(target: PreviewTarget) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var playback by remember(target) { mutableStateOf(PreviewAudioState.PREPARING) }
    val player = remember(target) { MediaPlayer() }
    DisposableEffect(player, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) playback = PreviewAudioPlayback.background(playback) {
                if (player.isPlaying) player.pause()
            }
        }
        lifecycle.addObserver(observer)
        try {
            player.setOnPreparedListener { if (playback == PreviewAudioState.PREPARING) playback = PreviewAudioState.PREPARED }
            player.setOnCompletionListener { if (playback !in listOf(PreviewAudioState.ERROR, PreviewAudioState.RELEASED)) playback = PreviewAudioState.COMPLETED }
            player.setOnErrorListener { _, _, _ -> if (playback != PreviewAudioState.RELEASED) playback = PreviewAudioState.ERROR; true }
            if (target.uri.scheme == "file") java.io.FileInputStream(File(requireNotNull(target.uri.path))).use { player.setDataSource(it.fd) }
            else player.setDataSource(context, target.uri)
            player.prepareAsync()
        } catch (_: Exception) { playback = PreviewAudioState.ERROR }
        onDispose {
            playback = PreviewAudioState.RELEASED
            lifecycle.removeObserver(observer)
            player.setOnPreparedListener(null); player.setOnCompletionListener(null); player.setOnErrorListener(null)
            player.release()
        }
    }
    when {
        playback == PreviewAudioState.ERROR -> FailedPreview()
        playback == PreviewAudioState.PREPARING -> LoadingPreview()
        playback != PreviewAudioState.RELEASED -> Button(onClick = {
            playback = PreviewAudioPlayback.toggle(playback, { player.start() }, { if (player.isPlaying) player.pause() })
        }) {
            Text(stringResource(if (playback == PreviewAudioState.PLAYING) R.string.preview_pause else R.string.preview_play))
        }
    }
}
