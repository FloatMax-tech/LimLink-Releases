package com.limlink.kit.lan

import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

data class DeviceBinding(val ownFP: String, val peerFP: String, val bindingId: String, val alias: String, val deviceType: String, val boundAt: Long)

object BindingValidation {
    val types = setOf("iphone", "ipad", "mac", "windows", "android")
    fun id(value: String): String { require(runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)) { "E_BAD_REQUEST" }; return value }
    fun deviceName(raw: String): String {
        val normalized = Normalizer.normalize(raw.trim(), Normalizer.Form.NFC)
        val result = StringBuilder()
        for (point in normalized.codePoints().toArray()) {
            if (Character.isISOControl(point)) continue
            val character = String(Character.toChars(point))
            if ((result.toString() + character).toByteArray(Charsets.UTF_8).size > 63) break
            result.append(character)
        }
        return result.toString().ifBlank { "Android" }
    }
    fun alias(value: String): String {
        require(value.isNotBlank() && value == Normalizer.normalize(value, Normalizer.Form.NFC) && value.toByteArray(Charsets.UTF_8).size <= 63 && value.none { Character.isISOControl(it) }) { "E_BAD_REQUEST" }
        return value
    }
    fun record(value: DeviceBinding) {
        require(Fingerprints.valid(value.ownFP) && Fingerprints.valid(value.peerFP) && value.ownFP != value.peerFP)
        id(value.bindingId); alias(value.alias); require(value.deviceType in types && value.boundAt >= 0)
    }
}

/** A private no-backup file. Reads and durable replacements are serialized and identity-scoped. */
open class BindingStore(private val file: File, val ownFP: String) {
    private var records = emptyList<DeviceBinding>()
    @Volatile var error: String? = null; private set
    init {
        require(Fingerprints.valid(ownFP))
        try {
            if (file.exists()) {
                val root = Json.parse(file.readBytes())
                require(Json.long(root, "version") == 1L && Json.text(root, "ownFP") == ownFP)
                records = root.getAsJsonArray("bindings").map { element ->
                    val j = element.asJsonObject
                    DeviceBinding(Json.text(j, "ownFP"), Json.text(j, "peerFP"), Json.text(j, "bindingId"), Json.text(j, "alias"), Json.text(j, "deviceType"), Json.long(j, "boundAt")).also {
                        BindingValidation.record(it); require(it.ownFP == ownFP)
                    }
                }
                require(records.distinctBy { it.peerFP }.size == records.size)
            }
        } catch (_: Exception) { records = emptyList(); error = "E_PAIR_STORAGE_FAILED" }
    }
    @Synchronized fun all(): List<DeviceBinding> = if (error == null) records.toList() else emptyList()
    @Synchronized fun active(peerFP: String): DeviceBinding? = if (error != null) null else records.firstOrNull { it.ownFP == ownFP && it.peerFP == peerFP }
    @Synchronized fun authorizes(peerFP: String, currentHelloId: String?): Boolean = currentHelloId != null && active(peerFP)?.bindingId == currentHelloId
    @Synchronized fun put(record: DeviceBinding) {
        BindingValidation.record(record); require(record.ownFP == ownFP)
        replace(records.filterNot { it.peerFP == record.peerFP } + record)
    }
    @Synchronized fun remove(peerFP: String, bindingId: String? = null) {
        val next = records.filterNot { it.peerFP == peerFP && (bindingId == null || it.bindingId == bindingId) }
        // Permission is cleared in memory even when storage is unavailable; never display success.
        try { replace(next) } catch (e: Exception) { records = next; throw e }
    }
    private fun replace(next: List<DeviceBinding>) {
        try { persist(Json.bytes(mapOf("version" to 1, "ownFP" to ownFP, "bindings" to next))); records = next; error = null }
        catch (e: Exception) { error = "E_PAIR_STORAGE_FAILED"; throw e }
    }
    protected open fun persist(bytes: ByteArray) {
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        val temporary = File.createTempFile("binding-", ".tmp", file.parentFile)
        try {
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { temporary.delete() }
    }
}

data class BindingPrompt(val pairId: String, val peerFP: String, val alias: String, val deviceType: String)

/** One service per runtime; each dispatcher supplies its own unforgeable connection owner. */
class BindingService(
    val store: BindingStore,
    private val alias: () -> String,
    private val changed: (BindingPrompt?) -> Unit = {},
    private val recordsChanged: () -> Unit = {},
    private val nanoTime: () -> Long = System::nanoTime,
    private val failed: (String) -> Unit = {},
) : Closeable {
    private data class Attempt(val owner: Any, val peer: String, val request: String, val prompt: BindingPrompt, val token: String, val started: Long, var state: String = "pending")
    private var attempt: Attempt? = null
    private val arrivals = java.util.ArrayDeque<Long>()
    private var stopped = false
    private var outgoing: Any? = null
    private var outgoingPeer: String? = null
    @Synchronized fun beginOutgoing(owner: Any, peer: String) { expire(); check(!stopped && outgoing == null && attempt?.state !in setOf("pending", "accepted")) { "E_PAIR_BUSY" }; outgoing = owner; outgoingPeer = peer }
    @Synchronized fun outgoingCurrent(owner: Any): Boolean = !stopped && outgoing === owner
    @Synchronized fun finishOutgoing(owner: Any) { if (outgoing === owner) { outgoing = null; outgoingPeer = null } }
    @Synchronized fun saveOutgoing(owner: Any, record: DeviceBinding, valid: () -> Boolean = { true }) {
        check(outgoingCurrent(owner) && valid()) { "E_PAIR_CANCELLED" }
        store.put(record)
        if (!outgoingCurrent(owner) || !valid()) { store.remove(record.peerFP, record.bindingId); recordsChanged(); error("E_PAIR_CANCELLED") }
        recordsChanged()
    }
    @Synchronized fun decide(id: String, accept: Boolean) {
        expire(); attempt?.takeIf { it.prompt.pairId == id && it.state == "pending" && !stopped }?.let {
            it.state = if (accept) "accepted" else "rejected"; changed(null)
        }
    }
    @Synchronized fun tick() { expire() }
    private fun expire() {
        attempt?.let { if (it.state != "expired" && nanoTime() - it.started >= TimeUnit.SECONDS.toNanos(120)) { it.state = "expired"; changed(null) } }
    }
    @Synchronized fun disconnected(owner: Any) {
        attempt?.takeIf { it.owner === owner && it.state in setOf("pending", "accepted") }?.let { it.state = "cancelled"; changed(null) }
    }
    /** Local device removal; the displayed ID can be stale after a replacement completes. */
    @Synchronized fun unbind(peer: String, displayedId: String? = null) {
        displayedId?.let { BindingValidation.id(it) }
        if (outgoingPeer == peer) { outgoing = null; outgoingPeer = null }
        // A local unbind also withdraws consent to an unfinished replacement.
        attempt?.takeIf { it.peer == peer && it.state in setOf("pending", "accepted") }?.let { it.state = "cancelled"; changed(null) }
        store.remove(peer); recordsChanged()
    }
    @Synchronized fun route(owner: Any, peer: String, frame: Frame): Frame {
        expire()
        return try {
            require(!stopped && Fingerprints.valid(peer) && peer != store.ownFP)
            require(frame.body.size <= 16_384 && frame.headers["x-limlink-app"] == "limlink") { "E_BAD_REQUEST" }
            val parts = frame.start.split(' '); require(parts.size == 3 && parts[2] == "HTTP/1.1")
            val method = parts[0]; val path = parts[1]
            val prefix = "${Limits.PREFIX}/pair/"
            require(path.startsWith(prefix))
            val suffix = path.removePrefix(prefix)
            if (method == "POST" && suffix == "start") {
                val j = frame.json
                if (j["version"]?.toString() != "1") return Wire.error("E_PAIR_VERSION")
                val request = BindingValidation.id(Json.text(j, "requestId"))
                val name = BindingValidation.alias(Json.text(j, "alias")); val type = Json.text(j, "deviceType"); require(type in BindingValidation.types)
                val live = attempt
                if (live != null && live.state in setOf("pending", "accepted") && live.owner === owner && live.peer == peer && live.request == request) return startResponse(live)
                if (outgoing != null || live?.state in setOf("pending", "accepted")) return Wire.error("E_PAIR_BUSY", 409)
                val now = nanoTime(); while (arrivals.isNotEmpty() && now - arrivals.first >= TimeUnit.SECONDS.toNanos(60)) arrivals.removeFirst()
                if (arrivals.size >= 3) return Wire.error("E_PAIR_RATE_LIMITED", 429)
                arrivals.addLast(now)
                val id = UUID.randomUUID().toString()
                val token = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
                val value = Attempt(owner, peer, request, BindingPrompt(id, peer, name, type), token, now)
                attempt = value; changed(value.prompt)
                return startResponse(value)
            }
            val bits = suffix.split('/'); val id = BindingValidation.id(bits[0])
            if (method == "POST" && bits.size == 2 && bits[1] == "revoke") {
                require(frame.json.entrySet().isEmpty())
                // A delayed remote revoke only targets its exact relationship.
                attempt?.takeIf { it.peer == peer && it.prompt.pairId == id }?.let { it.state = "cancelled"; changed(null) }
                try { store.remove(peer, id); recordsChanged() } catch (_: Exception) { failed("E_PAIR_STORAGE_FAILED"); recordsChanged(); return Wire.error("E_PAIR_STORAGE_FAILED", 500) }; return Wire.response(200, mapOf("state" to "revoked"))
            }
            val current = attempt?.takeIf { it.prompt.pairId == id } ?: return Wire.error("E_PAIR_EXPIRED", 410)
            val token = frame.headers["x-limlink-pair-token"].orEmpty()
            if (current.owner !== owner || current.peer != peer || !MessageDigest.isEqual(current.token.toByteArray(), token.toByteArray())) return Wire.error("E_PAIR_TOKEN_INVALID", 403)
            if (current.state == "expired") return Wire.error("E_PAIR_EXPIRED", 410)
            if (method == "GET" && bits.size == 1) return status(current)
            require(method == "POST" && bits.size == 2 && frame.json.entrySet().isEmpty())
            if (bits[1] == "cancel") {
                current.state = "cancelled"; changed(null)
                try { store.remove(peer, id); recordsChanged() } catch (_: Exception) { failed("E_PAIR_STORAGE_FAILED"); recordsChanged(); return Wire.error("E_PAIR_STORAGE_FAILED", 500) }
                return Wire.response(200, mapOf("state" to "cancelled"))
            }
            require(bits[1] == "complete")
            if (current.state == "completed") {
                if (!store.authorizes(peer, id)) return Wire.error("E_PAIR_NOT_ACCEPTED", 409)
                return status(current)
            }
            if (current.state != "accepted") return Wire.error("E_PAIR_NOT_ACCEPTED", 409)
            try {
                store.put(DeviceBinding(store.ownFP, peer, id, current.prompt.alias, current.prompt.deviceType, System.currentTimeMillis() / 1000))
                current.state = "completed"; changed(null); recordsChanged(); status(current)
            } catch (_: Exception) { current.state = "failed"; changed(null); failed("E_PAIR_STORAGE_FAILED"); recordsChanged(); Wire.error("E_PAIR_STORAGE_FAILED", 500) }
        } catch (_: Exception) { Wire.error("E_BAD_REQUEST") }
    }
    private fun startResponse(a: Attempt) = Wire.response(202, mapOf("version" to 1, "pairId" to a.prompt.pairId, "token" to a.token, "state" to "pending", "expiresInSeconds" to remaining(a), "alias" to alias(), "deviceType" to "android"))
    private fun remaining(a: Attempt) = ((TimeUnit.SECONDS.toNanos(120) - (nanoTime() - a.started)).coerceAtLeast(0) / 1_000_000_000L).toInt()
    private fun status(a: Attempt) = Wire.response(200, mapOf("version" to 1, "pairId" to a.prompt.pairId, "state" to a.state, "expiresInSeconds" to remaining(a)))
    @Synchronized override fun close() { stopped = true; outgoing = null; attempt?.state = "cancelled"; changed(null) }
}

/** Initiator's Bind click is its grant. Only the remote UI may transition pending to accepted. */
class BindingClient(
    private val service: BindingService,
    private val exchange: Exchange,
    private val peerFP: String,
    private val nanoTime: () -> Long = System::nanoTime,
    private val wait: () -> Unit = { Thread.sleep(1_000) },
) {
    fun bind(owner: Any, alias: String, cancelled: () -> Boolean = { false }): DeviceBinding {
        require(Fingerprints.valid(peerFP) && peerFP != service.store.ownFP)
        val deadline = nanoTime() + TimeUnit.SECONDS.toNanos(120)
        var pairId: String? = null
        var token: String? = null
        fun request(method: String, path: String, body: ByteArray = byteArrayOf()): Frame {
            check(!cancelled() && service.outgoingCurrent(owner)) { "E_PAIR_CANCELLED" }
            check(nanoTime() < deadline) { "E_PAIR_EXPIRED" }
            val response = exchange.request(method, path, body, token?.let { mapOf("x-limlink-pair-token" to it) } ?: emptyMap())
            check(response.body.size <= 16_384 && response.status < 400) { runCatching { Json.text(response.json, "code") }.getOrDefault("E_BAD_RESPONSE") }
            return response
        }
        try {
            val start = request("POST", "${Limits.PREFIX}/pair/start", Json.bytes(mapOf("version" to 1, "requestId" to UUID.randomUUID().toString(), "alias" to BindingValidation.alias(alias), "deviceType" to "android")))
            require(start.status == 202 && Json.long(start.json, "version") == 1L && Json.text(start.json, "state") == "pending")
            pairId = BindingValidation.id(Json.text(start.json, "pairId"))
            token = Json.text(start.json, "token").also { require(Fingerprints.valid(it)) }
            val peerAlias = BindingValidation.alias(Json.text(start.json, "alias")); val type = Json.text(start.json, "deviceType"); require(type in BindingValidation.types)
            val path = "${Limits.PREFIX}/pair/$pairId"
            while (true) {
                wait()
                val poll = request("GET", path)
                require(poll.status == 200 && Json.long(poll.json, "version") == 1L && Json.text(poll.json, "pairId") == pairId)
                when (Json.text(poll.json, "state")) {
                    "pending" -> continue
                    "accepted" -> break
                    else -> error("E_PAIR_${Json.text(poll.json, "state").uppercase()}")
                }
            }
            val complete = request("POST", "$path/complete", Json.bytes(emptyMap<String, String>()))
            require(complete.status == 200 && Json.long(complete.json, "version") == 1L && Json.text(complete.json, "pairId") == pairId && Json.text(complete.json, "state") == "completed")
            check(!cancelled() && nanoTime() < deadline) { "E_PAIR_CANCELLED" }
            val record = DeviceBinding(service.store.ownFP, peerFP, pairId, peerAlias, type, System.currentTimeMillis() / 1000)
            service.saveOutgoing(owner, record) { !cancelled() && nanoTime() < deadline }
            return record
        } catch (e: Exception) {
            if (pairId != null && token != null) runCatching { exchange.request("POST", "${Limits.PREFIX}/pair/$pairId/cancel", Json.bytes(emptyMap<String, String>()), mapOf("x-limlink-pair-token" to token!!)) }
            throw e
        } finally { service.finishOutgoing(owner) }
    }
}
