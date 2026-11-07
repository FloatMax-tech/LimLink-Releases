package com.limlink.kit.lan

import com.limlink.kit.storage.IncomingStore
import com.limlink.kit.storage.PublishedFile
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 255) }

class Snapshot private constructor(val file: File, val name: String, val size: Long, val sha256: String) : Closeable {
    private var references = 1
    private var ownerClosed = false
    @Synchronized fun acquire(): Lease? {
        if (ownerClosed || !file.isFile) return null
        references++
        return Lease(file, ::release)
    }
    @Synchronized private fun release() { references--; if (references == 0) file.delete() }
    @Synchronized override fun close() { if (!ownerClosed) { ownerClosed = true; release() } }
    class Lease internal constructor(val file: File, private val release: () -> Unit) : Closeable {
        private var closed = false
        @Synchronized override fun close() { if (!closed) { closed = true; release() } }
    }
    companion object {
        fun capture(input: InputStream, name: String, directory: File, cancelled: () -> Boolean = { false }): Snapshot {
            Limits.name(name)
            check(directory.isDirectory || directory.mkdirs())
            val target = File.createTempFile("send-", ".part", directory)
            try {
                val hash = MessageDigest.getInstance("SHA-256")
                var size = 0L
                input.use { source -> FileOutputStream(target).use { output ->
                    val buffer = ByteArray(Limits.CHUNK)
                    while (true) {
                        check(!cancelled()) { "E_SESSION_CANCELLED" }
                        val count = source.read(buffer)
                        if (count < 0) break
                        size += count; Limits.size(size)
                        output.write(buffer, 0, count); hash.update(buffer, 0, count)
                    }
                    output.fd.sync()
                } }
                return Snapshot(target, name, size, hash.digest().hex())
            } catch (error: Throwable) { target.delete(); throw error }
        }
    }
}

data class Offer(val sessionId: String, val senderName: String, val fileName: String, val size: Long, val peerFingerprint: String = "", val automatic: Boolean = false, val bindingId: String? = null)

/** One instance belongs to exactly one authenticated TLS connection. Sessions never migrate. */
class ReceiverConnection(
    private val directory: File,
    private val alias: () -> String,
    private val port: Int,
    private val consent: (Offer) -> CompletableFuture<Boolean>,
    private val store: () -> IncomingStore,
    private val progress: (Offer, Long) -> Unit = { _, _ -> },
    private val completed: (Offer, PublishedFile) -> Unit = { _, _ -> },
    private val dismissed: (String) -> Unit = {},
    private val interrupted: (Offer) -> Unit = {},
    private val nanoTime: () -> Long = System::nanoTime,
    private val peerFingerprint: String = "",
    private val binding: BindingService? = null,
    private val connectionOwner: Any = Any(),
) : Closeable {
    private var sender: String? = null
    private var helloBindingId: String? = null
    @Volatile var fileConnection: Boolean = false; private set
    @Volatile var pairingConnection: Boolean = false; private set
    @Volatile private var session: Session? = null
    @Volatile private var closed = false
    private data class Session(
        val offer: Offer, val fileId: String, val clientKey: String, val token: String,
        val file: File, val decision: CompletableFuture<Boolean>, val created: Long,
        val startedAt: Long = System.currentTimeMillis() / 1000,
        var offset: Long = 0, var digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
        var final: PublishedFile? = null, var mismatches: Int = 0,
    )
    fun handle(frame: Frame): Frame {
        if (closed) return Wire.error("E_SESSION_CANCELLED", 410)
        return try { route(frame) } catch (error: Exception) {
            when (error) {
                is com.google.gson.JsonParseException, is ClassCastException -> Wire.error("E_BAD_REQUEST")
                is IllegalArgumentException, is ArithmeticException, is IllegalStateException -> {
                    val code = error.message?.takeIf { it.startsWith("E_") } ?: "E_BAD_REQUEST"
                    val status = when (code) { "E_FILE_TOO_LARGE" -> 413; "E_INVALID_STATE", "E_BUSY" -> 409; "E_NOT_IMPLEMENTED" -> 501; else -> 400 }
                    Wire.error(code, status)
                }
                else -> { close(); Wire.error("E_WRITE_FAILED", 500) }
            }
        }
    }
    private fun route(frame: Frame): Frame {
        require(frame.headers["x-limlink-app"] == "limlink") { "E_APP_MISMATCH" }
        val parts = frame.start.split(' ')
        require(parts.size == 3 && parts[2] == "HTTP/1.1")
        val method = parts[0]; val path = parts[1].substringBefore('?')
        if (path.startsWith("${Limits.PREFIX}/pair/")) {
            require(!fileConnection)
            pairingConnection = true
            return binding?.route(connectionOwner, peerFingerprint, frame) ?: Wire.error("E_NOT_IMPLEMENTED", 501)
        }
        if (method == "POST" && path == "${Limits.PREFIX}/hello") {
            require(!pairingConnection)
            fileConnection = true
            require(session == null && sender == null) { "E_INVALID_STATE" }
            val json = frame.json
            require(Json.text(json, "app") == "limlink") { "E_APP_MISMATCH" }
            require(json.getAsJsonArray("proto").any { it.isJsonPrimitive && it.asJsonPrimitive.isString && it.asString == "1.0" })
            sender = Json.text(json, "alias").also { require(it.isNotBlank() && it.length <= 128 && it.none { c -> c.code < 32 }) }
            helloBindingId = if (json.has("bindingId")) runCatching { BindingValidation.id(Json.text(json, "bindingId")) }.getOrNull() else null
            val response = mutableMapOf<String, Any>("proto" to listOf("1.0"), "alias" to alias(), "devType" to "android", "port" to port, "app" to "limlink", "trusted" to false, "busy" to false, "caps" to listOf("binding-v1"))
            binding?.store?.active(peerFingerprint)?.let { response["bindingId"] = it.bindingId }
            return Wire.response(200, response)
        }
        require(sender != null) { "E_INVALID_STATE" }
        if (method == "POST" && path == "${Limits.PREFIX}/sessions") { synchronized(this) {
            check(!closed) { "E_SESSION_CANCELLED" }
            val json = frame.json
            require(Json.text(json, "transport") == "lan") { "E_NOT_IMPLEMENTED" }
            require(!json.has("inviteTicket") && !json.has("inviteSessionId"))
            val key = Limits.id(Json.text(json, "clientSessionKey"))
            session?.let {
                require(it.clientKey == key) { "E_BUSY" }
                return Wire.response(202, mapOf("sessionId" to it.offer.sessionId, "state" to "pending"))
            }
            val entries = json.getAsJsonArray("entries"); require(entries.size() == 1 && Json.long(json, "totalEntries") == 1L)
            val entry = entries[0].asJsonObject; require(Json.text(entry, "kind") == "file")
            val size = Limits.size(Json.long(entry, "size")); require(Json.long(json, "totalBytes") == size)
            val name = Limits.name(Json.text(entry, "relativePath")); val fileId = Limits.id(Json.text(entry, "id"))
            check(directory.isDirectory || directory.mkdirs())
            val id = UUID.randomUUID().toString()
            val file = File.createTempFile("receive-", ".part", directory)
            val offer = Offer(id, requireNotNull(sender), name, size, peerFingerprint, binding?.store?.authorizes(peerFingerprint, helloBindingId) == true, helloBindingId)
            try {
                session = Session(offer, fileId, key, UUID.randomUUID().toString(), file, consent(offer), nanoTime())
            } catch (error: Throwable) { file.delete(); throw error }
            return Wire.response(202, mapOf("sessionId" to id, "state" to "pending"))
        } }
        val current = session ?: return Wire.error("E_SESSION_NOT_FOUND", 404)
        val base = "${Limits.PREFIX}/sessions/${current.offer.sessionId}"
        if (path != base && !path.startsWith("$base/")) return Wire.error("E_SESSION_NOT_FOUND", 404)
        if (!current.decision.isDone && elapsed(current) >= Limits.TIMEOUT_MS) { close(); return Wire.error("E_DECISION_TIMEOUT", 408) }
        if (method == "GET" && path == base) {
            if (!current.decision.isDone) {
                try { current.decision.get(minOf(25_000L, Limits.TIMEOUT_MS - elapsed(current)), TimeUnit.MILLISECONDS) }
                catch (_: TimeoutException) { return Wire.response(202, mapOf("sessionId" to current.offer.sessionId, "state" to "pending")) }
            }
            if (current.decision.getNow(false) != true) { close(); return Wire.error("E_REJECTED", 403) }
            dismissed(current.offer.sessionId)
            return Wire.response(200, mapOf("state" to "accepted", "files" to mapOf(current.fileId to mapOf("accept" to true, "token" to current.token, "offset" to current.offset, "finalName" to current.offer.fileName, "state" to "accepted"))))
        }
        if (method == "POST" && path == "$base/cancel") { close(); return Wire.response(200, mapOf("state" to "cancelled")) }
        if (!current.decision.isDone || current.decision.getNow(false) != true) return Wire.error("E_INVALID_STATE", 409)
        if (method == "PUT" && path == "$base/files/${current.fileId}") { synchronized(this) {
            check(!closed) { "E_SESSION_CANCELLED" }
            if (current.final != null) return Wire.error("E_INVALID_STATE", 409)
            if (frame.headers["x-limlink-token"] != current.token) return Wire.error("E_TOKEN_INVALID", 403)
            val rawOffset = frame.headers["x-limlink-offset"] ?: ""
            if (!rawOffset.matches(Regex("[0-9]+")) || rawOffset.toLongOrNull() != current.offset) return Wire.error("E_OFFSET_MISMATCH", 409)
            require(frame.body.size <= Limits.CHUNK && frame.body.size.toLong() <= current.offer.size - current.offset)
            require(frame.headers["content-type"] == "application/octet-stream")
            RandomAccessFile(current.file, "rw").use { output ->
                check(output.length() == current.offset); output.seek(current.offset); output.write(frame.body); output.fd.sync()
            }
            current.digest.update(frame.body); current.offset += frame.body.size
            progress(current.offer, current.offset)
            return Wire.response(200, mapOf("committedBytes" to current.offset))
        } }
        if (method == "POST" && path == "$base/files/${current.fileId}/complete") {
            synchronized(this) {
                check(!closed) { "E_SESSION_CANCELLED" }
                require(current.final == null) { "E_INVALID_STATE" }
                val claimed = Json.text(frame.json, "sha256").lowercase(); require(claimed.matches(Regex("[0-9a-f]{64}")))
                if (current.offset != current.offer.size || current.digest.digest().hex() != claimed) {
                    current.mismatches++
                    if (current.mismatches > 1) close() else {
                        RandomAccessFile(current.file, "rw").use { it.setLength(0) }; current.offset = 0; current.digest = MessageDigest.getInstance("SHA-256")
                    }
                    return Wire.error("E_CHECKSUM_MISMATCH", 422)
                }
            }
            val destination = store()
            val pending = destination.begin(current.offer.fileName, "application/octet-stream")
            try {
                current.file.inputStream().use { input ->
                    val buffer = ByteArray(Limits.CHUNK)
                    while (true) {
                        check(!closed) { "E_SESSION_CANCELLED" }
                        val count = input.read(buffer); if (count < 0) break
                        destination.write(pending, if (count == buffer.size) buffer else buffer.copyOf(count))
                    }
                }
                synchronized(this) {
                    check(!closed) { "E_SESSION_CANCELLED" }
                    current.final = destination.publish(pending)
                }
            } catch (error: Throwable) { runCatching { destination.discard(pending) }; close(); throw error } finally {
                // close() may run while the input is open; retry cleanup after use releases it.
                current.file.delete()
            }
            completed(current.offer, requireNotNull(current.final))
            return Wire.response(200, mapOf("verified" to true, "finalName" to requireNotNull(current.final).displayName))
        }
        if (method == "POST" && path == "$base/finish") {
            val final = current.final ?: return Wire.error("E_INVALID_STATE", 409)
            return Wire.response(200, mapOf("sessionId" to current.offer.sessionId, "state" to "finished", "startedAt" to current.startedAt, "finishedAt" to System.currentTimeMillis() / 1000, "durationMs" to elapsed(current), "totals" to mapOf("files" to 1, "completed" to 1, "failed" to 0, "verifyFailed" to 0, "rejected" to 0, "cancelled" to 0, "bytesPlanned" to current.offer.size, "bytesReceived" to current.offset), "files" to listOf(mapOf("id" to current.fileId, "state" to "completed", "sha256Match" to true, "size" to current.offer.size, "bytesReceived" to current.offset, "relativePath" to current.offer.fileName, "finalName" to final.displayName, "renamed" to (final.displayName != current.offer.fileName), "errorCode" to null))))
        }
        return Wire.error("E_NOT_IMPLEMENTED", 501)
    }
    private fun elapsed(session: Session): Long = TimeUnit.NANOSECONDS.toMillis(nanoTime() - session.created)
    fun approvalExpired(): Boolean = session?.let { !it.decision.isDone && elapsed(it) >= Limits.TIMEOUT_MS } ?: false
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        binding?.disconnected(connectionOwner)
        session?.let {
            if (it.final == null && it.decision.isDone && !it.decision.isCancelled && it.decision.getNow(false) == true) interrupted(it.offer)
            it.decision.cancel(false); it.file.delete(); dismissed(it.offer.sessionId)
        }
    }
}

fun interface Exchange { fun request(method: String, path: String, body: ByteArray, headers: Map<String, String>): Frame }

class FileSender @JvmOverloads constructor(private val exchange: Exchange, private val bindingId: String? = null) {
    fun send(snapshot: Snapshot, alias: String, port: Int, cancelled: () -> Boolean = { false }, progress: (Long) -> Unit = {}): String {
        fun request(method: String, path: String, body: ByteArray = byteArrayOf(), headers: Map<String, String> = emptyMap()): Frame {
            check(!cancelled()) { "E_SESSION_CANCELLED" }
            val response = exchange.request(method, path, body, headers)
            check(response.status < 400) { runCatching { Json.text(response.json, "code") }.getOrDefault("E_BAD_RESPONSE") }
            return response
        }
        val hello = request("POST", "${Limits.PREFIX}/hello", Json.bytes(mapOf("proto" to listOf("1.0"), "app" to "limlink", "alias" to alias, "devType" to "android", "port" to port, "caps" to listOf("binding-v1")) + (bindingId?.let { mapOf("bindingId" to it) } ?: emptyMap())))
        require(hello.status == 200 && Json.text(hello.json, "app") == "limlink")
        val fileId = UUID.randomUUID().toString()
        val created = request("POST", "${Limits.PREFIX}/sessions", Json.bytes(mapOf("clientSessionKey" to UUID.randomUUID().toString(), "transport" to "lan", "totalEntries" to 1, "totalBytes" to snapshot.size, "entries" to listOf(mapOf("id" to fileId, "kind" to "file", "relativePath" to snapshot.name, "size" to snapshot.size)))))
        require(created.status == 202)
        val sessionId = Limits.id(Json.text(created.json, "sessionId")); val base = "${Limits.PREFIX}/sessions/$sessionId"
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(Limits.TIMEOUT_MS.toLong())
        var token: String
        while (true) {
            check(System.nanoTime() < deadline) { "E_DECISION_TIMEOUT" }
            val poll = request("GET", "$base?wait=25")
            if (poll.status == 202) { Thread.sleep(100); continue }
            require(poll.status == 200 && Json.text(poll.json, "state") == "accepted")
            val file = poll.json.getAsJsonObject("files").getAsJsonObject(fileId)
            require(Json.long(file, "offset") == 0L && Json.bool(file, "accept"))
            token = Json.text(file, "token"); require(token.isNotBlank()); break
        }
        var checksumRetries = 0
        lateinit var completed: Frame
        while (true) {
            RandomAccessFile(snapshot.file, "r").use { source ->
                var offset = 0L
                do {
                    val count = minOf(Limits.CHUNK.toLong(), snapshot.size - offset).toInt()
                    val buffer = ByteArray(count); source.readFully(buffer)
                    val ack = request("PUT", "$base/files/$fileId", buffer, mapOf("x-limlink-token" to token, "x-limlink-offset" to offset.toString(), "content-type" to "application/octet-stream"))
                    require(ack.status == 200 && Json.long(ack.json, "committedBytes") == offset + count) { "E_OFFSET_MISMATCH" }
                    offset += count; progress(offset)
                } while (offset < snapshot.size)
            }
            try {
                completed = request("POST", "$base/files/$fileId/complete", Json.bytes(mapOf("sha256" to snapshot.sha256)))
                break
            } catch (error: IllegalStateException) {
                if (error.message != "E_CHECKSUM_MISMATCH" || checksumRetries++ != 0) throw error
                progress(0)
            }
        }
        require(completed.status == 200 && Json.bool(completed.json, "verified"))
        val name = Json.text(completed.json, "finalName"); require(name.isNotBlank())
        val finished = request("POST", "$base/finish")
        val json = finished.json
        require(finished.status == 200 && Json.text(json, "sessionId") == sessionId && Json.text(json, "state") == "finished")
        val files = json.getAsJsonArray("files"); require(files.size() == 1)
        val file = files[0].asJsonObject
        require(Json.text(file, "id") == fileId && Json.text(file, "state") == "completed" && Json.bool(file, "sha256Match") && Json.long(file, "size") == snapshot.size && Json.long(file, "bytesReceived") == snapshot.size && Json.text(file, "finalName") == name)
        return name
    }
}
