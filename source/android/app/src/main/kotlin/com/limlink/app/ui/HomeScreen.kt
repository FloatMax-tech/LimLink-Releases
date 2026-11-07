package com.limlink.app.ui

import android.Manifest
import android.os.Build
import android.os.SystemClock
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.StringRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.foundation.gestures.draggable
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.limlink.app.R
import com.limlink.app.storage.LocationKind
import com.limlink.app.storage.SaveLocationRepository
import com.limlink.app.storage.SaveLocationStatus
import com.limlink.app.transfer.HistoryEntry
import com.limlink.app.transfer.LanController
import com.limlink.app.transfer.LanPhase
import com.limlink.app.transfer.LanState
import com.limlink.app.transfer.rateLabel
import com.limlink.app.preview.FilePreviewDialog
import com.limlink.app.preview.PreviewTarget
import com.limlink.app.preview.ReceivedFileActions
import com.limlink.kit.lan.Peer
import com.limlink.ui.theme.LocalLimLinkTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class Page { Compose, Recipients, Progress }

private val SENDING_PHASES = listOf(LanPhase.WAITING, LanPhase.TRANSFERRING, LanPhase.COMPLETED, LanPhase.FAILED)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(onSettings: () -> Unit, modifier: Modifier = Modifier) {
    val state by LanController.state.collectAsState()
    val receive by LanController.receive.collectAsState()
    val peers by LanController.peers.collectAsState()
    val available by LanController.available.collectAsState()
    val history by LanController.history.collectAsState()
    val deviceName by LanController.name.collectAsState()
    var choosing by rememberSaveable { mutableStateOf(false) }
    var sources by rememberSaveable { mutableStateOf(false) }
    var preview by remember { mutableStateOf<PreviewTarget?>(null) }
    var selectedFiles by remember { mutableStateOf(false) }
    val receipt by LanController.receipt.collectAsState()
    val sendingFlow = !state.receiving && state.peer.isNotEmpty() && state.phase in SENDING_PHASES
    LaunchedEffect(sendingFlow) { if (sendingFlow) choosing = false }
    val page = when { sendingFlow -> Page.Progress; choosing -> Page.Recipients; else -> Page.Compose }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> if (uris.isNotEmpty()) LanController.selectAll(uris) }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris -> if (uris.isNotEmpty()) LanController.selectAll(uris) }
    val shareIntake by LanController.shareIntake.collectAsState()
    LaunchedEffect(shareIntake, state.phase) {
        if (shareIntake && state.phase == LanPhase.READY) {
            choosing = true
            LanController.clearShareIntake()
        }
    }
    val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(Unit) { if (Build.VERSION.SDK_INT >= 33) notifications.launch(Manifest.permission.POST_NOTIFICATIONS) }
    BackHandler(page == Page.Recipients) { choosing = false }
    BackHandler(page == Page.Progress && state.phase in listOf(LanPhase.COMPLETED, LanPhase.FAILED)) { LanController.reset() }

    val title = when (page) {
        Page.Compose -> R.string.brand_name
        Page.Recipients -> R.string.lan_choose_peer
        Page.Progress -> when (state.phase) {
            LanPhase.COMPLETED -> R.string.progress_title_done
            LanPhase.FAILED -> R.string.progress_title_failed
            else -> R.string.progress_title_sending
        }
    }
    Column(modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        TopBar(title, showBack = page == Page.Recipients, onBack = { choosing = false }, onSettings = onSettings)
        AnimatedContent(
            targetState = page,
            transitionSpec = {
                val direction = if (targetState.ordinal > initialState.ordinal) 1 else -1
                (fadeIn(tween(320, easing = ExpoOut)) + slideInHorizontally(tween(460, easing = ExpoOut)) { direction * it / 8 }) togetherWith
                    (fadeOut(tween(160)) + slideOutHorizontally(tween(260)) { -direction * it / 12 })
            },
            label = "page",
            modifier = Modifier.weight(1f),
        ) { target ->
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).widthIn(max = 720.dp)
                    .padding(horizontal = 22.dp).padding(top = 4.dp, bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                when (target) {
                    Page.Compose -> ComposePage(state, receive, history, available, deviceName,
                        onPick = { sources = true }, onSend = { choosing = true },
                        onPreview = { if (state.files.size > 1) selectedFiles = true else preview = LanController.selectedPreview(0) },
                        onReceivedPreview = { preview = LanController.receivedPreview(it) }, receipt = receipt)
                    Page.Recipients -> RecipientsPage(state, peers, available, deviceName)
                    Page.Progress -> ProgressPage(state, peers)
                }
            }
        }
    }
    if (sources) SourceSheet(
        onDismiss = { sources = false },
        onPhotos = { sources = false; photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) },
        onFiles = { sources = false; picker.launch(arrayOf("*/*")) },
    )
    if (selectedFiles) ModalBottomSheet(onDismissRequest = { selectedFiles = false }) {
        androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxWidth().heightIn(max = 440.dp).padding(bottom = 24.dp)) {
            items(state.files.size) { index ->
                val file = state.files[index]
                TextButton(onClick = { selectedFiles = false; preview = LanController.selectedPreview(index) }, modifier = Modifier.fillMaxWidth()) { Text(file.name) }
            }
        }
    }
    preview?.let { target -> FilePreviewDialog(target) { preview = null } }
}

@Composable
private fun TopBar(@StringRes title: Int, showBack: Boolean, onBack: () -> Unit, onSettings: () -> Unit) {
    Box(Modifier.fillMaxWidth().height(64.dp).padding(horizontal = 16.dp)) {
        AnimatedVisibility(showBack, Modifier.align(Alignment.CenterStart), enter = fadeIn() + scaleIn(initialScale = 0.7f), exit = fadeOut() + scaleOut(targetScale = 0.7f)) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.cd_back)) }
        }
        AnimatedContent(
            targetState = title,
            transitionSpec = { (fadeIn(tween(220)) + slideInVertically(tween(320, easing = ExpoOut)) { it / 3 }) togetherWith (fadeOut(tween(140)) + slideOutVertically(tween(200)) { -it / 3 }) },
            label = "title",
            modifier = Modifier.align(Alignment.Center),
        ) { Text(stringResource(it), fontSize = 21.sp, fontWeight = FontWeight.SemiBold) }
        val interaction = remember { MutableInteractionSource() }
        FilledIconButton(
            onClick = onSettings,
            interactionSource = interaction,
            modifier = Modifier.align(Alignment.CenterEnd).size(44.dp).pressScale(interaction),
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = MaterialTheme.colorScheme.surface, contentColor = MaterialTheme.colorScheme.onSurface),
        ) { Icon(Icons.Default.AccountCircle, stringResource(R.string.title_settings), Modifier.size(26.dp)) }
    }
}

@Composable
private fun StatusLine(available: Boolean, deviceName: String) {
    val theme = LocalLimLinkTheme.current
    val dot by animateColorAsState(if (available) theme.colors.signal else Color(0xFFFF9F0A), tween(400), label = "status-dot")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(7.dp).background(dot, CircleShape))
        Text(
            if (available) stringResource(R.string.status_ready, deviceName) else stringResource(R.string.status_starting),
            color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

// ---------- compose ----------

@Composable
private fun ColumnScope.ComposePage(
    state: LanState,
    receive: LanState?,
    history: List<HistoryEntry>,
    available: Boolean,
    deviceName: String,
    onPick: () -> Unit,
    onSend: () -> Unit,
    onPreview: () -> Unit,
    onReceivedPreview: (HistoryEntry) -> Unit,
    receipt: HistoryEntry?,
) {
    val context = LocalContext.current
    val theme = LocalLimLinkTheme.current
    StatusLine(available, deviceName)
    ReceiveSection(receive)
    ReceiptCompletion(receipt)
    val selected = state.phase == LanPhase.READY
    val preparing = state.phase == LanPhase.PREPARING
    val interaction = remember { MutableInteractionSource() }
    Surface(
        onClick = if (selected) onPreview else onPick, enabled = !preparing, interactionSource = interaction,
        shape = RoundedCornerShape(30.dp), color = MaterialTheme.colorScheme.surface,
        modifier = Modifier.fillMaxWidth().pressScale(interaction).appear(Appear.Rise).testTag("transfer.file.choose"),
    ) {
        Column(
            Modifier.padding(horizontal = 22.dp, vertical = 26.dp).animateContentSize(spring(dampingRatio = 0.8f, stiffness = 380f)),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            key(selected) { FileArt(selected) }
            AnimatedContent(
                targetState = Triple(selected, preparing, state.fileName),
                transitionSpec = { (fadeIn(tween(260)) + slideInVertically(tween(420, easing = ExpoOut)) { it / 4 }) togetherWith fadeOut(tween(120)) },
                label = "hero-text",
            ) { (isSelected, isPreparing, name) ->
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    when {
                        isPreparing -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Ring(0f, Modifier.size(18.dp), thickness = 2.dp, spinning = true)
                            Text(stringResource(R.string.lan_preparing), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        isSelected -> {
                            val multiple = state.files.size > 1
                            Text(
                                if (multiple) stringResource(R.string.compose_files_count, state.files.size) else name,
                                fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 3, overflow = TextOverflow.Ellipsis,
                            )
                            Text(Formatter.formatShortFileSize(context, state.size), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (multiple) Text(
                                state.files.take(3).joinToString(" · ") { it.name } + if (state.files.size > 3) " …" else "",
                                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                                maxLines = 2, overflow = TextOverflow.Ellipsis,
                            )
                            Text(stringResource(R.string.preview_tap), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            TextButton(onClick = onPick) { Text(stringResource(R.string.compose_change)) }
                        }
                        else -> {
                            Text(stringResource(R.string.compose_title), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            Text(stringResource(R.string.compose_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
    AnimatedVisibility(state.phase == LanPhase.FAILED && state.peer.isEmpty(), enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
        Text(stringResource(errorText(state.error, 0)), color = theme.colors.buttonDestructive, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
    Pill(
        text = stringResource(R.string.home_send), onClick = onSend, enabled = selected && available,
        trailingArrow = true, modifier = Modifier.fillMaxWidth().appear(Appear.Rise, 60).testTag("transfer.send"),
    )
    Text(stringResource(R.string.home_limit), Modifier.fillMaxWidth(), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
    ReceivedCard(history.filter { it.receiving }.take(4), onReceivedPreview)
}

@Composable private fun ReceiptCompletion(entry: HistoryEntry?) {
    if (entry == null) return
    LaunchedEffect(entry.locator) { delay(3500); LanController.clearReceipt(entry.locator) }
    Row(Modifier.fillMaxWidth().background(LocalLimLinkTheme.current.colors.signalSoft, RoundedCornerShape(18.dp)).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        key(entry.locator) { VerifiedCompletion(Modifier.size(48.dp)) }
        Text(stringResource(R.string.compose_received_banner, entry.fileName, entry.peer), Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun ReceiveSection(receive: LanState?) {
    val context = LocalContext.current
    val theme = LocalLimLinkTheme.current
    var last by remember { mutableStateOf(receive) }
    if (receive != null) last = receive
    AnimatedVisibility(receive != null, enter = fadeIn(tween(260)) + expandVertically(tween(420, easing = ExpoOut)), exit = fadeOut(tween(170)) + shrinkVertically(tween(260))) {
        val item = last ?: return@AnimatedVisibility
        when (item.phase) {
            LanPhase.TRANSFERRING -> Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    val fraction = if (item.size == 0L) 0f else item.transferred.toFloat() / item.size
                    Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                        Ring(fraction, Modifier.fillMaxSize(), thickness = 4.dp)
                        DocGlyph(Modifier.size(18.dp), arrow = 1)
                    }
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.receive_title, item.peer), color = theme.colors.signal, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(item.fileName, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(vertical = 2.dp))
                        Text(
                            stringResource(R.string.receive_progress, Formatter.formatShortFileSize(context, item.transferred), Formatter.formatShortFileSize(context, item.size), (fraction * 100).toInt()),
                            color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp,
                        )
                    }
                }
            }
            else -> {
                val ok = item.phase == LanPhase.COMPLETED
                if (ok) return@AnimatedVisibility // The durable receipt notice owns the verified animation.
                Row(
                    Modifier.fillMaxWidth().background(if (ok) theme.colors.signalSoft else theme.colors.dangerSoft, RoundedCornerShape(14.dp)).padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (ok) stringResource(R.string.compose_received_banner, item.fileName, item.peer) else stringResource(R.string.compose_receive_failed, item.fileName),
                        Modifier.weight(1f), fontSize = 14.sp,
                    )
                    IconButton(onClick = LanController::clearReceive) { Icon(Icons.Default.Close, stringResource(R.string.action_cancel), Modifier.size(18.dp)) }
                }
            }
        }
    }
}

@Composable
private fun ReceivedCard(received: List<HistoryEntry>, onPreview: (HistoryEntry) -> Unit) {
    val context = LocalContext.current
    val theme = LocalLimLinkTheme.current
    var pending by remember { mutableStateOf<HistoryEntry?>(null) }
    val failed = stringResource(R.string.delete_failed)
    Surface(shape = RoundedCornerShape(26.dp), color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth().appear(Appear.Rise, 120)) {
        Column(Modifier.padding(22.dp).animateContentSize(spring(dampingRatio = 0.85f, stiffness = 380f)), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(stringResource(R.string.home_received), fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                if (received.isNotEmpty()) Text(stringResource(R.string.received_swipe_hint), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (received.isEmpty()) Text(stringResource(R.string.home_received_empty), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp))
            received.forEachIndexed { index, entry ->
                key(entry.locator ?: System.identityHashCode(entry)) {
                    SwipeToDeleteRow(index, onDelete = { pending = entry }) {
                        Column {
                            Row(Modifier.fillMaxWidth().clickable { onPreview(entry) }.background(MaterialTheme.colorScheme.surface).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                FileBadge { DocGlyph(Modifier.size(20.dp), arrow = 1) }
                                Column(Modifier.weight(1f)) {
                                    Text(entry.fileName, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(stringResource(R.string.compose_received_from, entry.peer), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                                }
                            }
                            ReceivedFileActions(entry)
                        }
                    }
                }
            }
        }
    }
    pending?.let { entry ->
        AlertDialog(
            onDismissRequest = { pending = null },
            containerColor = MaterialTheme.colorScheme.surface,
            title = { Text(stringResource(R.string.delete_title)) },
            text = { Text(stringResource(R.string.delete_body, entry.fileName)) },
            confirmButton = {
                TextButton(onClick = {
                    pending = null
                    LanController.deleteReceived(entry) { ok -> if (!ok) android.widget.Toast.makeText(context, failed, android.widget.Toast.LENGTH_SHORT).show() }
                }) { Text(stringResource(R.string.action_delete), color = theme.colors.buttonDestructive, fontWeight = FontWeight.SemiBold) }
            },
            dismissButton = { TextButton(onClick = { pending = null }) { Text(stringResource(R.string.action_cancel), color = MaterialTheme.colorScheme.onSurface) } },
        )
    }
}

/**
 * Drag left to reveal a red delete area; releasing past the threshold asks for confirmation and the row
 * springs back either way. Deleting is permanent on Android, so it never happens on the gesture alone.
 */
@Composable
private fun SwipeToDeleteRow(index: Int, onDelete: () -> Unit, content: @Composable () -> Unit) {
    val theme = LocalLimLinkTheme.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    val threshold = with(density) { 96.dp.toPx() }
    val limit = with(density) { 160.dp.toPx() }
    val offset = remember { androidx.compose.animation.core.Animatable(0f) }
    val scope = rememberCoroutineScope()
    val drag = androidx.compose.foundation.gestures.rememberDraggableState { delta ->
        scope.launch {
            // Rubber-band resistance beyond the threshold.
            val next = offset.value + if (offset.value < -threshold) delta * 0.35f else delta
            offset.snapTo(next.coerceIn(-limit, 0f))
        }
    }
    Box(Modifier.fillMaxWidth().appear(Appear.Rise, index * 45)) {
        Box(
            Modifier.matchParentSize().background(theme.colors.buttonDestructive, RoundedCornerShape(14.dp)).padding(end = 22.dp),
            contentAlignment = Alignment.CenterEnd,
        ) {
            Icon(
                Icons.Default.Delete, stringResource(R.string.action_delete), tint = Color.White,
                modifier = Modifier.graphicsLayer {
                    val p = (-offset.value / threshold).coerceIn(0f, 1f)
                    alpha = p; scaleX = 0.6f + 0.4f * p; scaleY = 0.6f + 0.4f * p
                },
            )
        }
        Box(
            Modifier
                .offset { androidx.compose.ui.unit.IntOffset(offset.value.toInt(), 0) }
                .draggable(
                    state = drag,
                    orientation = androidx.compose.foundation.gestures.Orientation.Horizontal,
                    onDragStopped = {
                        if (offset.value <= -threshold) onDelete()
                        offset.animateTo(0f, spring(dampingRatio = 0.6f, stiffness = 420f))
                    },
                ),
        ) { content() }
    }
}

// ---------- recipients ----------

@Composable
private fun ColumnScope.RecipientsPage(state: LanState, peers: List<Peer>, available: Boolean, deviceName: String) {
    val context = LocalContext.current
    val theme = LocalLimLinkTheme.current
    var multi by rememberSaveable { mutableStateOf(false) }
    val selected = remember { mutableStateListOf<String>() }
    StatusLine(available, deviceName)
    if (state.phase == LanPhase.READY) Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth().appear(Appear.Rise)) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            FileBadge { DocGlyph(Modifier.size(20.dp)) }
            Column(Modifier.weight(1f)) {
                Text(
                    if (state.files.size > 1) stringResource(R.string.compose_files_count, state.files.size) else state.fileName,
                    fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
                Text(Formatter.formatShortFileSize(context, state.size), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
            }
        }
    }
    val empty = peers.isEmpty()
    val radarHeight by animateDpAsState(if (empty) 170.dp else 120.dp, spring(dampingRatio = 0.8f, stiffness = 300f), label = "radar-height")
    val radarScale by animateFloatAsState(if (empty) 1f else 0.7f, spring(dampingRatio = 0.8f, stiffness = 300f), label = "radar-scale")
    Box(Modifier.fillMaxWidth().height(radarHeight), contentAlignment = Alignment.Center) {
        Radar(active = available, modifier = Modifier.graphicsLayer { scaleX = radarScale; scaleY = radarScale })
    }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        AnimatedContent(targetState = empty, transitionSpec = { fadeIn(tween(260)) togetherWith fadeOut(tween(140)) }, label = "peers-title") { isEmpty ->
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(if (isEmpty) R.string.peers_empty_title else R.string.peers_title), fontSize = 23.sp, fontWeight = FontWeight.Bold)
                Text(stringResource(if (isEmpty) R.string.peers_empty_hint else R.string.peers_hint), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
        if (!empty) TextButton(
            onClick = { multi = !multi; if (!multi) selected.clear() },
        ) { Text(stringResource(if (multi) R.string.multi_done else R.string.multi_select), color = theme.colors.signal, fontWeight = FontWeight.SemiBold) }
    }
    val canSend = available && state.phase == LanPhase.READY
    peers.chunked(2).forEachIndexed { rowIndex, row ->
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.fillMaxWidth()) {
            row.forEachIndexed { column, peer ->
                key(peer.fingerprint) {
                    PeerTile(
                        peer, enabled = canSend, index = rowIndex * 2 + column, multi = multi,
                        checked = peer.fingerprint in selected, modifier = Modifier.weight(1f),
                    ) {
                        if (multi) {
                            if (peer.fingerprint in selected) selected.remove(peer.fingerprint) else selected.add(peer.fingerprint)
                        } else LanController.send(peer)
                    }
                }
            }
            if (row.size == 1) Spacer(Modifier.weight(1f))
        }
    }
    if (multi) Pill(
        stringResource(R.string.send_to_devices, selected.size),
        onClick = {
            val targets = peers.filter { it.fingerprint in selected }
            if (targets.isNotEmpty()) { multi = false; selected.clear(); LanController.sendAll(targets) }
        },
        enabled = canSend && selected.isNotEmpty(),
        centered = true,
        modifier = Modifier.fillMaxWidth().appear(Appear.Rise),
    )
}

@Composable
private fun PeerTile(
    peer: Peer,
    enabled: Boolean,
    index: Int,
    modifier: Modifier,
    multi: Boolean = false,
    checked: Boolean = false,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val label = stringResource(typeLabel(peer.deviceType))
    val theme = LocalLimLinkTheme.current
    Surface(
        onClick = onClick, enabled = enabled, interactionSource = interaction,
        shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface,
        border = if (multi && checked) androidx.compose.foundation.BorderStroke(2.dp, theme.colors.signal) else null,
        modifier = modifier.pressScale(interaction).appear(Appear.Rise, index * 45).testTag("transfer.peer.${peer.fingerprint}"),
    ) {
        Box {
            Column(Modifier.fillMaxWidth().padding(18.dp).heightIn(min = 112.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                DeviceGlyph(peer.deviceType, Modifier.size(38.dp))
                Text(displayName(peer), fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (multi) {
                Box(
                    Modifier.align(Alignment.TopEnd).padding(12.dp).size(22.dp)
                        .background(if (checked) theme.colors.signal else androidx.compose.ui.graphics.Color.Transparent, CircleShape)
                        .border(1.5.dp, if (checked) theme.colors.signal else MaterialTheme.colorScheme.onSurfaceVariant, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    if (checked) Icon(Icons.Default.Check, null, Modifier.size(14.dp), tint = Color.White)
                }
            }
        }
    }
}

/** Windows hosts append "-" and six fingerprint characters to their DNS-SD instance name. */
fun displayName(peer: Peer): String {
    val suffix = "-" + peer.fingerprint.take(6)
    return if (peer.name.length > suffix.length && peer.name.endsWith(suffix, ignoreCase = true)) peer.name.dropLast(suffix.length) else peer.name
}

@StringRes
private fun typeLabel(type: String): Int = when (type) {
    "windows" -> R.string.type_windows
    "mac" -> R.string.type_mac
    "iphone" -> R.string.type_iphone
    "ipad" -> R.string.type_ipad
    "android" -> R.string.type_android
    else -> R.string.type_device
}

// ---------- progress ----------

@Composable
private fun ColumnScope.ProgressPage(state: LanState, peers: List<Peer>) {
    val context = LocalContext.current
    val theme = LocalLimLinkTheme.current
    val ink = MaterialTheme.colorScheme.onSurface
    val track = ink.copy(alpha = 0.1f)
    val peer = peers.firstOrNull { it.fingerprint == state.peerId }
    val peerName = peer?.let(::displayName) ?: state.peer
    val done = state.phase == LanPhase.COMPLETED
    val failed = state.phase == LanPhase.FAILED
    val waiting = state.phase == LanPhase.WAITING
    val batch = state.files.size > 1
    val fraction = when {
        state.totalSize == 0L -> if (waiting) 0f else 1f
        else -> (state.totalTransferred.toFloat() / state.totalSize).coerceIn(0f, 1f)
    }
    // Show the delivered result briefly, then return to the empty composer without a tap.
    LaunchedEffect(done) {
        if (!done) return@LaunchedEffect
        delay(3000)
        if (LanController.state.value.phase == LanPhase.COMPLETED) LanController.reset()
    }
    var lastStep by remember { mutableIntStateOf(1) }
    val step = when {
        done -> 4
        failed -> lastStep
        waiting -> 1
        state.transferred >= state.size -> 3
        else -> 2
    }
    if (!failed) lastStep = step
    val rate = rememberRate(state.transferred, step == 2)

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
        DeviceGlyph(peer?.deviceType ?: "device", Modifier.size(20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(R.string.progress_to, peerName), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
    }
    Box(Modifier.size(270.dp), contentAlignment = Alignment.Center) {
        key(done, failed) {
            when {
                done -> {
                    VerifiedCompletion(Modifier.size(240.dp))
                }
                failed -> {
                    Ring(fraction, Modifier.size(240.dp), thickness = 20.dp, color = theme.colors.buttonDestructive, track = track, drawIn = true)
                    Icon(Icons.Default.Warning, null, Modifier.size(64.dp).shake(Unit), tint = theme.colors.buttonDestructive)
                }
                else -> {
                    Ring(fraction, Modifier.size(240.dp), thickness = 20.dp, color = ink, track = track, spinning = waiting)
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        AnimatedVisibility(!waiting, enter = fadeIn() + scaleIn(initialScale = 0.85f), exit = fadeOut()) {
                            Text("${(fraction * 100).toInt()}%", fontSize = 46.sp, fontWeight = FontWeight.SemiBold)
                        }
                        Text(
                            stringResource(R.string.progress_bytes, Formatter.formatShortFileSize(context, state.totalTransferred), Formatter.formatShortFileSize(context, state.totalSize)),
                            color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp,
                        )
                    }
                }
            }
        }
    }
    Text(
        if (batch) stringResource(R.string.compose_files_count, state.files.size) else state.fileName,
        fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
    )
    if (batch && state.fileName.isNotEmpty()) Text(
        stringResource(R.string.progress_file_index, state.fileIndex, state.files.size, state.fileName),
        color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
    )
    val status = when {
        done && batch -> stringResource(R.string.progress_done_batch, state.completedFiles, peerName)
        done -> stringResource(R.string.progress_done_detail, peerName, state.fileName)
        failed && state.error.contains("E_BATCH_PARTIAL") -> stringResource(R.string.error_batch_partial)
        failed -> stringResource(errorText(state.error, lastStep), peerName)
        step == 1 -> stringResource(R.string.progress_waiting, peerName)
        step == 3 -> stringResource(R.string.progress_verifying, peerName)
        else -> stringResource(R.string.progress_sending, peerName)
    }
    AnimatedContent(targetState = status, transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(120)) }, label = "status") {
        Text(it, color = if (failed) theme.colors.buttonDestructive else if (done) MaterialTheme.colorScheme.onSurfaceVariant else theme.colors.signal, fontWeight = if (done) FontWeight.Normal else FontWeight.SemiBold, textAlign = TextAlign.Center, fontSize = 14.sp)
    }
    AnimatedVisibility(step == 2 && rate > 0, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
        Row(horizontalArrangement = Arrangement.spacedBy(36.dp)) {
            Stat(rateLabel(context, rate.toLong()), stringResource(R.string.progress_speed))
            Stat(remainingText(if (rate > 0) (state.size - state.transferred) / rate else 0.0), stringResource(R.string.progress_remaining))
        }
    }
    StepRow(listOf(stringResource(R.string.step_connect), stringResource(R.string.step_accept), stringResource(R.string.step_transfer), stringResource(R.string.step_verify)), step)
    Spacer(Modifier.weight(1f).heightIn(min = 12.dp))
    when {
        done -> Pill(stringResource(R.string.action_send_another), onClick = LanController::reset, modifier = Modifier.fillMaxWidth().appear(Appear.Rise, 320), centered = true)
        failed -> Pill(stringResource(R.string.action_back_home), onClick = LanController::reset, modifier = Modifier.fillMaxWidth().appear(Appear.Rise, 200), centered = true)
        else -> Pill(stringResource(R.string.action_cancel_send), onClick = LanController::cancel, style = PillStyle.Danger, modifier = Modifier.fillMaxWidth(), centered = true)
    }
}

@Composable
private fun Stat(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Exponential moving average of bytes per second, sampled at most every 500 ms. */
@Composable
private fun rememberRate(bytes: Long, active: Boolean): Double {
    var rate by remember { mutableDoubleStateOf(0.0) }
    val sample = remember { longArrayOf(0L, 0L) }
    LaunchedEffect(bytes, active) {
        val now = SystemClock.elapsedRealtime()
        if (!active) { rate = 0.0; sample[0] = now; sample[1] = bytes; return@LaunchedEffect }
        if (sample[0] == 0L) { sample[0] = now; sample[1] = bytes; return@LaunchedEffect }
        val elapsed = (now - sample[0]) / 1000.0
        if (elapsed >= 0.5) {
            val instant = (bytes - sample[1]) / elapsed
            rate = if (rate == 0.0) instant else rate * 0.7 + instant * 0.3
            sample[0] = now; sample[1] = bytes
        }
    }
    return rate
}

@Composable
private fun remainingText(seconds: Double): String = when {
    seconds < 1 -> stringResource(R.string.remaining_less)
    seconds < 60 -> stringResource(R.string.remaining_seconds, kotlin.math.ceil(seconds).toInt())
    else -> stringResource(R.string.remaining_minutes, kotlin.math.ceil(seconds / 60).toInt())
}

@StringRes
private fun errorText(error: String, step: Int): Int = when {
    error.contains("E_REJECTED") || (error.contains("E_INVALID_STATE") && step <= 1) -> R.string.error_rejected
    error.contains("E_DECISION_TIMEOUT") || (step <= 1 && error.contains("timed out", ignoreCase = true)) -> R.string.error_timeout
    error.contains("E_BUSY") -> R.string.error_busy
    error.contains("E_FILE_TOO_LARGE") -> R.string.error_too_large
    error.contains("E_APP_MISMATCH") -> R.string.error_mismatch
    error.contains("E_WRITE_FAILED") -> R.string.error_write
    error.contains("E_CHECKSUM_MISMATCH") -> R.string.error_checksum
    step == 0 -> R.string.error_select
    error.contains("E_DISCONNECTED") || error.contains("reset", ignoreCase = true) || error.contains("closed", ignoreCase = true) -> R.string.error_disconnected
    else -> R.string.error_generic
}

// ---------- shared controls ----------

enum class PillStyle { Primary, Secondary, Danger }

@Composable
fun Pill(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    style: PillStyle = PillStyle.Primary,
    trailingArrow: Boolean = false,
    centered: Boolean = false,
) {
    val theme = LocalLimLinkTheme.current
    val interaction = remember { MutableInteractionSource() }
    val container = when (style) {
        PillStyle.Primary -> theme.colors.buttonPrimaryBackground
        PillStyle.Secondary -> theme.colors.buttonSecondaryBackground
        PillStyle.Danger -> theme.colors.dangerSoft
    }
    val content = when (style) {
        PillStyle.Primary -> theme.colors.buttonPrimaryForeground
        PillStyle.Secondary -> theme.colors.buttonSecondaryForeground
        PillStyle.Danger -> theme.colors.buttonDestructive
    }
    val alpha by animateFloatAsState(if (enabled) 1f else 0.3f, tween(220), label = "pill-alpha")
    Surface(
        onClick = onClick, enabled = enabled, interactionSource = interaction, shape = CircleShape,
        color = container, contentColor = content,
        modifier = modifier.height(52.dp).pressScale(interaction).graphicsLayer { this.alpha = alpha },
    ) {
        Row(Modifier.padding(horizontal = 22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = if (centered) Arrangement.Center else Arrangement.Start) {
            Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            if (trailingArrow) {
                Spacer(Modifier.weight(1f))
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(22.dp).rotate(-45f))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SourceSheet(onDismiss: () -> Unit, onPhotos: () -> Unit, onFiles: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(bottom = 28.dp)) {
            Text(stringResource(R.string.home_source_title), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 26.dp, vertical = 8.dp))
            SourceRow(R.string.source_photos, R.string.source_photos_hint, "transfer.source.photos", 0, onPhotos) { PhotoGlyph() }
            SourceRow(R.string.source_files, R.string.source_files_hint, "transfer.source.files", 1, onFiles) { FolderGlyph() }
        }
    }
}

@Composable
private fun SourceRow(@StringRes title: Int, @StringRes hint: Int, tag: String, index: Int, onClick: () -> Unit, icon: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).appear(Appear.Rise, 60 + index * 45).testTag(tag).padding(horizontal = 26.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        icon()
        Column {
            Text(stringResource(title), fontSize = 16.sp)
            Text(stringResource(hint), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun PhotoGlyph() {
    val ink = MaterialTheme.colorScheme.onSurface
    Canvas(Modifier.size(26.dp)) {
        val u = size.minDimension / 24f
        drawRoundRect(ink, Offset(3 * u, 5 * u), Size(18 * u, 14 * u), CornerRadius(2.5f * u), style = Stroke(1.7f * u))
        drawCircle(ink, radius = 1.6f * u, center = Offset(9 * u, 10 * u), style = Stroke(1.5f * u))
        drawLine(ink, Offset(21 * u, 16 * u), Offset(16 * u, 11 * u), 1.7f * u, StrokeCap.Round)
        drawLine(ink, Offset(16 * u, 11 * u), Offset(7 * u, 19 * u), 1.7f * u, StrokeCap.Round)
    }
}

@Composable
private fun FolderGlyph() {
    val ink = MaterialTheme.colorScheme.onSurface
    Canvas(Modifier.size(26.dp)) {
        val u = size.minDimension / 24f
        val path = androidx.compose.ui.graphics.Path().apply {
            moveTo(3 * u, 7 * u); lineTo(9 * u, 7 * u); lineTo(11 * u, 9 * u); lineTo(21 * u, 9 * u); lineTo(21 * u, 19 * u); lineTo(3 * u, 19 * u); close()
        }
        drawPath(path, ink, style = Stroke(1.7f * u, join = androidx.compose.ui.graphics.StrokeJoin.Round))
    }
}

// ---------- consent ----------

/**
 * Consent panel drawn above every page inside the activity window, so it never depends on a separate
 * dialog window. Back declines, like the receiver's own timeout.
 */
@Composable
fun ReceiveConsent() {
    val offers by LanController.offers.collectAsState()
    val context = LocalContext.current
    val theme = LocalLimLinkTheme.current
    val repository = remember { SaveLocationRepository(context.applicationContext) }
    val location by repository.status.collectAsState(SaveLocationStatus(LocationKind.DOWNLOADS, null, null))
    val saveLabel = when (location.kind) {
        LocationKind.TREE_OK -> location.treeLabel ?: stringResource(R.string.location_custom)
        else -> stringResource(R.string.location_downloads)
    }
    val current = offers.firstOrNull()
    var shown by remember { mutableStateOf(current) }
    if (current != null) shown = current
    BackHandler(current != null) { LanController.decide(current!!.sessionId, false) }

    AnimatedVisibility(current != null, enter = fadeIn(tween(220)), exit = fadeOut(tween(220))) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.32f)).clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {})
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(
            current != null,
            enter = slideInVertically(tween(460, easing = ExpoOut)) { it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(260)) { it } + fadeOut(tween(200)),
        ) {
            val offer = shown ?: return@AnimatedVisibility
            Surface(
                shape = RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp),
                color = MaterialTheme.colorScheme.surface,
                modifier = Modifier.fillMaxWidth().widthIn(max = 640.dp),
            ) {
                key(offer.sessionId) {
                    var secondsLeft by remember { mutableIntStateOf(120) }
                    LaunchedEffect(offer.sessionId) {
                        val arrival = LanController.offerArrivals[offer.sessionId] ?: SystemClock.elapsedRealtime()
                        while (true) {
                            secondsLeft = (120 - (SystemClock.elapsedRealtime() - arrival) / 1000).toInt().coerceAtLeast(0)
                            delay(1000)
                        }
                    }
                    Column(
                        Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp).padding(top = 12.dp, bottom = 24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(Modifier.size(38.dp, 5.dp).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f), CircleShape))
                        Box(Modifier.padding(top = 18.dp).size(64.dp).appear(Appear.Pop, 120), contentAlignment = Alignment.Center) {
                            Ring(0f, Modifier.fillMaxSize(), thickness = 6.dp, spinning = true)
                            DocGlyph(Modifier.size(22.dp), arrow = 1)
                        }
                        Text(stringResource(R.string.consent_title, offer.senderName), fontSize = 20.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center, lineHeight = 27.sp, modifier = Modifier.padding(top = 14.dp).appear(Appear.Rise, 160))
                        Row(
                            Modifier.padding(top = 18.dp, bottom = 10.dp).fillMaxWidth().appear(Appear.Rise, 200).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f), RoundedCornerShape(18.dp)).padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            FileBadge(background = MaterialTheme.colorScheme.surface) { DocGlyph(Modifier.size(20.dp)) }
                            Column(Modifier.weight(1f)) {
                                Text(offer.fileName, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                Text(stringResource(R.string.consent_detail, Formatter.formatShortFileSize(context, offer.size), saveLabel), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        Text(stringResource(R.string.consent_note), fontSize = 12.5.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.padding(bottom = 18.dp))
                        Pill(stringResource(R.string.lan_accept), onClick = { LanController.decide(offer.sessionId, true) }, centered = true, modifier = Modifier.fillMaxWidth().appear(Appear.Rise, 240).testTag("transfer.offer.accept"))
                        Spacer(Modifier.height(10.dp))
                        Pill(stringResource(R.string.lan_reject), onClick = { LanController.decide(offer.sessionId, false) }, style = PillStyle.Secondary, centered = true, modifier = Modifier.fillMaxWidth().appear(Appear.Rise, 280).testTag("transfer.offer.reject"))
                        Text(stringResource(R.string.consent_countdown, secondsLeft), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f), modifier = Modifier.padding(top = 12.dp))
                        if (offers.size > 1) Text(stringResource(R.string.consent_more, offers.size - 1), fontSize = 12.sp, color = theme.colors.signal, modifier = Modifier.padding(top = 4.dp))
                    }
                }
            }
        }
    }
}
