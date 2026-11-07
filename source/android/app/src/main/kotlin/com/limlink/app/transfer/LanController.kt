package com.limlink.app.transfer

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import com.limlink.app.storage.SaveLocationRepository
import com.limlink.kit.lan.*
import com.limlink.app.preview.PhotoLibrary
import com.limlink.app.preview.PhotoState
import com.limlink.app.preview.PreviewKind
import com.limlink.app.preview.PreviewPolicy
import com.limlink.app.preview.PreviewTarget
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

enum class LanPhase { IDLE, PREPARING, READY, WAITING, TRANSFERRING, COMPLETED, FAILED, CANCELLED }
data class LanFile(val name: String, val size: Long, val mime: String = "application/octet-stream", val originalLocator: String? = null)
data class LanState(
    val phase: LanPhase = LanPhase.IDLE,
    val fileName: String = "",
    val size: Long = 0,
    val transferred: Long = 0,
    val peer: String = "",
    val receiving: Boolean = false,
    val error: String = "",
    val peerId: String = "",
    /** All files staged for this outgoing batch, in capture order. */
    val files: List<LanFile> = emptyList(),
    /** 1-based index of [fileName] within the batch. */
    val fileIndex: Int = 0,
    /** Successful files so far; failed files are counted by the UI from the batch result. */
    val completedFiles: Int = 0,
    /** Bytes over the whole batch, including files still queued. */
    val totalSize: Long = 0,
    /** Bytes delivered over the whole batch, including completed files. */
    val totalTransferred: Long = 0,
)
/** [locator] is the saved file (MediaStore or SAF document URI, or a path) for received entries. */
data class HistoryEntry(
    val fileName: String, val peer: String, val size: Long, val receiving: Boolean, val locator: String? = null,
    val photoState: PhotoState = PhotoState.NONE, val galleryUri: String? = null, val mime: String = "application/octet-stream",
)

data class BindingState(val state: String = "idle", val peer: String = "", val error: String = "")

object LanController {
    private val mutableBindingPrompt = MutableStateFlow<BindingPrompt?>(null)
    val bindingPrompt = mutableBindingPrompt.asStateFlow()
    private val mutableBindings = MutableStateFlow<List<DeviceBinding>>(emptyList())
    val bindings = mutableBindings.asStateFlow()
    private val mutableBindingState = MutableStateFlow(BindingState())
    val bindingState = mutableBindingState.asStateFlow()
    private val pairingGeneration = AtomicLong(0)
    @Volatile private var bindingService: BindingService? = null

    private lateinit var context: android.app.Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableState = MutableStateFlow(LanState())
    val state = mutableState.asStateFlow()
    private val mutablePeers = MutableStateFlow<List<Peer>>(emptyList())
    val peers = mutablePeers.asStateFlow()
    private val mutableOffers = MutableStateFlow<List<Offer>>(emptyList())
    val offers = mutableOffers.asStateFlow()
    /** Incoming transfer, kept apart from [state] so a selected outgoing file survives a receive. */
    private val mutableReceive = MutableStateFlow<LanState?>(null)
    val receive = mutableReceive.asStateFlow()
    /** Elapsed-realtime arrival of each pending offer, for the 120 second countdown. */
    val offerArrivals = ConcurrentHashMap<String, Long>()
    /** Set by MainActivity; consent requests use a heads-up notification only while in the background. */
    @Volatile var foreground = false
    /** Local SPKI fingerprint, shown in Diagnostics for troubleshooting and protocol probes. */
    private val mutableFingerprint = MutableStateFlow("")
    val fingerprint = mutableFingerprint.asStateFlow()
    private val mutableHistory = MutableStateFlow<List<HistoryEntry>>(emptyList())
    val history = mutableHistory.asStateFlow()
    private val mutableReceipt = MutableStateFlow<HistoryEntry?>(null)
    val receipt = mutableReceipt.asStateFlow()
    private val photoJobs = mutableMapOf<String, Deferred<String>>()
    private val mutableName = MutableStateFlow("")
    val name = mutableName.asStateFlow()
    private val mutableAvailable = MutableStateFlow(false)
    val available = mutableAvailable.asStateFlow()
    private val imports = ConcurrentHashMap<Long, java.io.InputStream>()
    private val decisions = ConcurrentHashMap<String, CompletableFuture<Boolean>>()
    private val generation = AtomicLong(0)
    private val lifecycle = AtomicLong(0)
    @Volatile private var runtime: LanRuntime? = null
    @Volatile private var discovery: LanDiscovery? = null
    private var snapshots: List<Snapshot> = emptyList()
    private var startingEpoch: Long? = null
    private val startupLock = kotlinx.coroutines.sync.Mutex()
    private var recovered = false
    private val staging get() = File(context.filesDir, "lan-staging")

    fun initialize(value: android.app.Application) {
        context = value
        PhotoLibrary.initialize(value)
        scope.launch {
            val recovered = runCatching { PhotoLibrary.recover(value) }.getOrDefault(emptyList()).map { result ->
                val target = result.target
                HistoryEntry(target.name, target.senderName ?: "LimLink", target.size, true, target.locator,
                    photoState = if (result.galleryUri == null) PhotoState.FAILED else PhotoState.SAVED,
                    galleryUri = result.galleryUri, mime = target.mime)
            }
            mutableHistory.update { current -> (current + recovered).distinctBy { it.locator }.take(100) }
        }
        mutableName.value = BindingValidation.deviceName(context.getSharedPreferences("device", Context.MODE_PRIVATE).getString("name", null)
            ?: Build.MODEL.takeIf { it.isNotBlank() && it != Build.UNKNOWN } ?: "Android")
    }
    @Synchronized fun start() {
        if (runtime != null || startingEpoch != null) return
        val lifecycleEpoch = lifecycle.get()
        startingEpoch = lifecycleEpoch
        scope.launch {
            startupLock.lock()
            var localNetwork: LanRuntime? = null
            var localDiscovery: LanDiscovery? = null
            try {
                if (lifecycle.get() != lifecycleEpoch) return@launch
                if (!recovered) {
                    staging.listFiles()?.forEach { it.delete() }; staging.mkdirs()
                    com.limlink.kit.storage.PendingJournal.recover(context)
                    recovered = true
                }
                val identity = AndroidIdentity()
                mutableFingerprint.value = identity.fingerprint
                val bindingStore = BindingStore(File(context.noBackupFilesDir, "device-bindings-v1.json"), identity.fingerprint)
                mutableBindings.value = bindingStore.all()
                if (bindingStore.error != null) mutableBindingState.value = BindingState("failed", error = bindingStore.error!!)
                val binding = BindingService(bindingStore, { name.value },
                    changed = { prompt -> if (lifecycle.get() == lifecycleEpoch) mutableBindingPrompt.value = prompt },
                    recordsChanged = { if (lifecycle.get() == lifecycleEpoch) mutableBindings.value = bindingStore.all() },
                    failed = { if (lifecycle.get() == lifecycleEpoch) mutableBindingState.value = BindingState("failed", error = it) })
                val network = LanRuntime(identity, binding) { port, peerFingerprint ->
                    val transferEpoch = generation.get()
                    ReceiverConnection(staging, { name.value }, port,
                        consent = { offer ->
                            val future = CompletableFuture<Boolean>()
                            if (generation.get() != transferEpoch || lifecycle.get() != lifecycleEpoch) future.complete(false)
                            else if (offer.automatic && bindingStore.authorizes(offer.peerFingerprint, offer.bindingId)) future.complete(true)
                            else {
                                decisions[offer.sessionId] = future
                                offerArrivals[offer.sessionId] = android.os.SystemClock.elapsedRealtime()
                                mutableOffers.update { if (generation.get() == transferEpoch) it + offer else it }
                            }
                            future
                        },
                        store = {
                            val repository = SaveLocationRepository(context)
                            val status = runBlocking { repository.status.first() }
                            repository.openStore(status).store
                        },
                        progress = { offer, bytes ->
                            if (lifecycle.get() == lifecycleEpoch) mutableReceive.value = LanState(LanPhase.TRANSFERRING, offer.fileName, offer.size, bytes, offer.senderName, true)
                        },
                        completed = { offer, file ->
                            if (lifecycle.get() == lifecycleEpoch) {
                                mutableReceive.value = LanState(LanPhase.COMPLETED, file.displayName, offer.size, offer.size, offer.senderName, true)
                                val entry = HistoryEntry(file.displayName, offer.senderName, offer.size, true, file.locator)
                                mutableHistory.update { (listOf(entry) + it).take(100) }
                                mutableReceipt.value = entry
                                scope.launch { prepareReceivedPreview(entry) }
                            }
                        },
                        interrupted = { offer ->
                            mutableReceive.update { value ->
                                if (value != null && value.peer == offer.senderName && value.fileName == offer.fileName && value.phase == LanPhase.TRANSFERRING) value.copy(phase = LanPhase.FAILED, error = "E_DISCONNECTED") else value
                            }
                        },
                        peerFingerprint = peerFingerprint, binding = binding,
                        dismissed = { id -> decisions.remove(id); offerArrivals.remove(id); mutableOffers.update { offers -> offers.filterNot { it.sessionId == id } } },
                    )
                }
                localNetwork = network
                val advertisement = LanDiscovery(context, identity.fingerprint,
                    { values -> if (lifecycle.get() == lifecycleEpoch) mutablePeers.value = values },
                    { scope.launch {
                        synchronized(this@LanController) {
                            if (lifecycle.get() == lifecycleEpoch && runtime === network) {
                                stop()
                                fail("E_DISCOVERY_FAILED")
                            }
                        }
                    } },
                )
                localDiscovery = advertisement
                // Publish and start resources under the same lock used by stop; a stale startup
                // can never leave a listener, advertisement or a true readiness flag behind.
                synchronized(this@LanController) {
                    if (lifecycle.get() != lifecycleEpoch) return@launch
                    network.start()
                    advertisement.start(name.value, network.port)
                    runtime = network; bindingService = binding; discovery = advertisement
                    mutableAvailable.value = true
                    localNetwork = null; localDiscovery = null
                }
            } catch (error: Exception) {
                synchronized(this@LanController) {
                    if (lifecycle.get() == lifecycleEpoch) { mutableAvailable.value = false; fail(error.message.orEmpty()) }
                }
            } finally {
                localDiscovery?.close(); localNetwork?.close()
                synchronized(this@LanController) { if (startingEpoch == lifecycleEpoch) startingEpoch = null }
                startupLock.unlock()
            }
        }
    }
    fun bind(peer: Peer) {
        if (mutableBindingState.value.state == "waiting") return
        val epoch = pairingGeneration.incrementAndGet()
        val run = lifecycle.get()
        mutableBindingState.value = BindingState("waiting", peer.name)
        scope.launch {
            try {
                requireNotNull(runtime).bind(peer, name.value) { pairingGeneration.get() != epoch || lifecycle.get() != run }
                if (pairingGeneration.get() == epoch && lifecycle.get() == run) mutableBindingState.value = BindingState("completed", peer.name)
            } catch (e: Exception) {
                if (pairingGeneration.get() == epoch && lifecycle.get() == run) mutableBindingState.value = BindingState("failed", peer.name, e.message.orEmpty())
            }
        }
    }
    fun decideBinding(id: String, accept: Boolean) { bindingService?.decide(id, accept) }
    fun cancelBinding() { pairingGeneration.incrementAndGet(); runtime?.cancelPairing(); mutableBindingState.value = BindingState("cancelled") }
    fun unbind(record: DeviceBinding) {
        scope.launch {
            try {
                requireNotNull(bindingService).unbind(record.peerFP, record.bindingId)
                mutableBindings.value = bindingService?.store?.all().orEmpty()
                mutableBindingState.value = BindingState("unbound", record.alias)
                peers.value.firstOrNull { it.fingerprint == record.peerFP }?.let { peer -> runCatching { runtime?.revoke(peer, record.bindingId) } }
            } catch (e: Exception) { mutableBindings.value = bindingService?.store?.all().orEmpty(); mutableBindingState.value = BindingState("failed", record.alias, "E_PAIR_STORAGE_FAILED") }
        }
    }
    @Synchronized fun rename(raw: String) {
        val clean = BindingValidation.deviceName(raw)
        if (clean.isEmpty()) return
        context.getSharedPreferences("device", Context.MODE_PRIVATE).edit().putString("name", clean).apply()
        mutableName.value = clean
        runtime?.let { discovery?.advertise(clean, it.port) }
    }
    /** True when a file arrived from the system share sheet and the app should jump to the device list. */
    private val mutableShareIntake = MutableStateFlow(false)
    val shareIntake = mutableShareIntake.asStateFlow()

    fun selectFromShare(uri: Uri) {
        mutableShareIntake.value = true
        select(uri)
    }

    fun clearShareIntake() { mutableShareIntake.value = false }

    fun select(uri: Uri) = selectAll(listOf(uri))

    /** Captures every shared/picked document in order, then publishes the batch only when all are ready. */
    fun selectAll(uris: List<Uri>) {
        if (uris.isEmpty()) return
        val epoch = generation.incrementAndGet()
        synchronized(this) { snapshots.forEach { it.close() }; snapshots = emptyList() }
        mutableState.value = LanState(LanPhase.PREPARING)
        scope.launch {
            val captured = mutableListOf<Snapshot>()
            val metadata = mutableListOf<LanFile>()
            try {
                for (uri in uris) {
                    if (generation.get() != epoch) break
                    var name = "file"
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            name = cursor.getString(0) ?: name
                            if (!cursor.isNull(1)) Limits.size(cursor.getLong(1))
                        }
                    }
                    val source = requireNotNull(context.contentResolver.openInputStream(uri))
                    imports[epoch] = source
                    val file = try { source.use { Snapshot.capture(it, name, staging) { generation.get() != epoch } } } finally { imports.remove(epoch) }
                    captured += file
                    metadata += LanFile(file.name, file.size, PreviewPolicy.mime(file.name, runCatching { context.contentResolver.getType(uri) }.getOrNull()), uri.toString())
                }
                synchronized(this@LanController) {
                    if (generation.get() != epoch) { captured.forEach { it.close() }; return@synchronized }
                    snapshots.forEach { it.close() }; snapshots = captured
                    val files = metadata.toList()
                    val total = files.sumOf { it.size }
                    mutableState.value = LanState(LanPhase.READY, files.first().name, total, files = files, totalSize = total)
                }
            } catch (error: Exception) {
                captured.forEach { it.close() }
                mutableState.update { if (generation.get() == epoch) it.copy(phase = LanPhase.FAILED, error = error.message.orEmpty()) else it }
            }
        }
    }

    fun send(peer: Peer) = sendAll(listOf(peer))

    /**
     * Sends every staged file to each device in turn. A failed file does not stop the batch; the caller
     * retries the selection from the start, matching the Windows client's partial-result behaviour.
     */
    fun sendAll(peers: List<Peer>) {
        if (peers.isEmpty()) return
        val sources: List<Snapshot>
        synchronized(this) { sources = snapshots; snapshots = emptyList() }
        if (sources.isEmpty()) return
        val epoch = generation.get()
        val files = sources.map { LanFile(it.name, it.size) }
        val total = files.sumOf { it.size }
        scope.launch {
            var ok = 0
            var failed = 0
            var delivered = 0L
            var lastError = ""
            try {
                for (peer in peers) {
                    for ((index, source) in sources.withIndex()) {
                        if (generation.get() != epoch) return@launch
                        val completed = ok
                        mutableState.value = LanState(
                            LanPhase.WAITING, source.name, source.size, peer = peer.name, peerId = peer.fingerprint,
                            files = files, fileIndex = index + 1, completedFiles = completed, totalSize = total, totalTransferred = delivered,
                        )
                        try {
                            val network = requireNotNull(runtime)
                            val finalName = network.send(peer, source, name.value, { generation.get() != epoch }) { bytes ->
                                mutableState.update {
                                    if (generation.get() == epoch) LanState(
                                        LanPhase.TRANSFERRING, source.name, source.size, bytes, peer.name, peerId = peer.fingerprint,
                                        files = files, fileIndex = index + 1, completedFiles = completed, totalSize = total, totalTransferred = delivered + bytes,
                                    ) else it
                                }
                            }
                            mutableHistory.update { (listOf(HistoryEntry(finalName, peer.name, source.size, false)) + it).take(100) }
                            delivered += source.size
                            ok++
                        } catch (error: Exception) {
                            if (generation.get() != epoch) return@launch
                            failed++
                            lastError = error.message.orEmpty()
                        }
                    }
                }
                mutableState.update {
                    if (generation.get() != epoch) it
                    else if (failed == 0) it.copy(
                        phase = LanPhase.COMPLETED, fileName = if (files.size == 1) it.fileName else "", size = total,
                        transferred = total, completedFiles = ok, totalTransferred = total, error = "",
                    )
                    else it.copy(
                        phase = LanPhase.FAILED, completedFiles = ok, totalTransferred = delivered,
                        error = if (ok > 0) "E_BATCH_PARTIAL" else lastError.ifBlank { "E_BATCH" },
                    )
                }
            } finally {
                sources.forEach { it.close() }
            }
        }
    }

    fun decide(id: String, accept: Boolean) {
        val offer = mutableOffers.value.firstOrNull { it.sessionId == id }
        decisions[id]?.complete(accept)
        offerArrivals.remove(id)
        mutableOffers.update { it.filterNot { item -> item.sessionId == id } }
        if (accept && offer != null) mutableReceive.value = LanState(LanPhase.TRANSFERRING, offer.fileName, offer.size, 0, offer.senderName, true)
    }
    @Synchronized fun cancel() {
        generation.incrementAndGet(); imports.values.forEach { runCatching { it.close() } }; imports.clear(); runtime?.cancelTransfers()
        synchronized(this) { snapshots.forEach { it.close() }; snapshots = emptyList() }
        decisions.values.forEach { it.complete(false) }; decisions.clear(); offerArrivals.clear(); mutableOffers.value = emptyList()
        mutableState.value = mutableState.value.copy(phase = LanPhase.CANCELLED)
        mutableReceive.update { if (it?.phase == LanPhase.TRANSFERRING) it.copy(phase = LanPhase.CANCELLED) else it }
    }
    /** Returns from a finished outgoing transfer to the empty composer. */
    @Synchronized fun reset() {
        if (mutableState.value.phase in listOf(LanPhase.COMPLETED, LanPhase.FAILED, LanPhase.CANCELLED)) mutableState.value = LanState()
    }
    /** Deletes a received file from where it was saved, then drops it from the list. A file that is already gone counts as deleted. */
    fun deleteReceived(entry: HistoryEntry, done: (Boolean) -> Unit) {
        scope.launch {
            val deleted = runCatching {
                val locator = entry.locator ?: return@runCatching true
                val removed = if (locator.startsWith("content://")) {
                    val uri = Uri.parse(locator)
                    try {
                        if (android.provider.DocumentsContract.isDocumentUri(context, uri)) android.provider.DocumentsContract.deleteDocument(context.contentResolver, uri)
                        else { context.contentResolver.delete(uri, null, null); true }
                    } catch (_: java.io.FileNotFoundException) { true }
                } else File(locator).let { !it.exists() || it.delete() }
                if (removed) receivedPreview(entry)?.let { PhotoLibrary.forgetRecovery(context, it) }
                removed
            }.getOrDefault(false)
            if (deleted) mutableHistory.update { history -> history.filterNot { it === entry || (entry.locator != null && it.locator == entry.locator) } }
            withContext(Dispatchers.Main) { done(deleted) }
        }
    }
    fun clearReceive() { mutableReceive.update { if (it?.phase == LanPhase.TRANSFERRING) it else null } }
    fun clearReceipt(locator: String?) { mutableReceipt.update { if (it?.locator == locator) null else it } }

    /** The caller owns the returned lease; replacing/sending the selection cannot expire it. */
    @Synchronized fun selectedPreview(index: Int): PreviewTarget? {
        if (mutableState.value.phase != LanPhase.READY) return null
        val source = snapshots.getOrNull(index) ?: return null
        val file = mutableState.value.files.getOrNull(index) ?: return null
        val lease = source.acquire() ?: return null
        return PreviewTarget(lease.file.absolutePath, file.name, file.mime, file.size, originalLocator = file.originalLocator, lease = lease)
    }
    fun receivedPreview(entry: HistoryEntry): PreviewTarget? = entry.locator?.takeIf { entry.receiving && PreviewPolicy.localLocator(it) }?.let {
        PreviewTarget(it, entry.fileName, PreviewPolicy.mime(entry.fileName, entry.mime), entry.size, received = true,
            galleryUri = entry.galleryUri, senderName = entry.peer)
    }

    private suspend fun prepareReceivedPreview(entry: HistoryEntry) {
        val target = receivedPreview(entry) ?: return
        val guessed = PreviewPolicy.mime(entry.fileName)
        val mime = if (guessed != "application/octet-stream") guessed else runCatching {
            target.open(context).use { input ->
                val header = ByteArray(32); var count = 0
                while (count < header.size) { val n = input.read(header, count, header.size - count); if (n <= 0) break; count += n }
                PreviewPolicy.sniff(header.copyOf(count))
            }
        }.getOrNull() ?: guessed
        val image = PreviewPolicy.kind(entry.fileName, mime) == PreviewKind.IMAGE
        val autoSave = PhotoLibrary.autoSave.value
        val resolved = entry.copy(mime = mime, photoState = if (image) { if (autoSave) PhotoState.SAVING else PhotoState.DISABLED } else PhotoState.NONE)
        mutableHistory.update { entries -> entries.map { current ->
            if (current.locator != entry.locator) current else current.copy(mime = mime,
                photoState = if (current.photoState in listOf(PhotoState.NONE, PhotoState.DISABLED)) resolved.photoState else current.photoState)
        } }
        if (image && autoSave) runCatching { exportImage(receivedPreview(resolved) ?: return) }
    }

    /** Export belongs to the controller; dismissing a preview must not cancel publication halfway. */
    suspend fun exportImage(target: PreviewTarget): String {
        require(target.received && target.kind == PreviewKind.IMAGE)
        val key = target.locator
        val job = synchronized(photoJobs) {
            photoJobs[key] ?: scope.async(start = CoroutineStart.LAZY) {
                mutableHistory.update { entries -> entries.map { if (it.locator == key) it.copy(photoState = PhotoState.SAVING) else it } }
                try {
                    val uri = PhotoLibrary.export(context, target)
                    mutableHistory.update { entries -> entries.map { if (it.locator == key) it.copy(photoState = PhotoState.SAVED, galleryUri = uri) else it } }
                    uri
                } catch (error: Exception) {
                    mutableHistory.update { entries -> entries.map { if (it.locator == key) it.copy(photoState = PhotoState.FAILED) else it } }
                    throw error
                } finally { synchronized(photoJobs) { photoJobs.remove(key) } }
            }.also { photoJobs[key] = it }
        }
        job.start()
        return job.await()
    }
    fun retryGallery(entry: HistoryEntry) { receivedPreview(entry)?.let { target -> scope.launch { runCatching { exportImage(target) } } } }
    @Synchronized fun stop() { lifecycle.incrementAndGet(); cancelBinding(); bindingService?.close(); bindingService = null; mutableBindingPrompt.value = null; startingEpoch = null; cancel(); discovery?.close(); discovery = null; runtime?.close(); runtime = null; mutablePeers.value = emptyList(); mutableAvailable.value = false }
    private fun fail(code: String) { mutableState.value = mutableState.value.copy(phase = LanPhase.FAILED, error = code) }
    private fun record(entry: HistoryEntry, epoch: Long) { mutableHistory.update { if (generation.get() == epoch) (listOf(entry) + it).take(100) else it } }
}
