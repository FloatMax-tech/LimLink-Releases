package com.limlink.kit.lan

import org.junit.Test
import org.junit.Assert.*
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CompletableFuture

class BindingControlTest {
    @get:Rule val folder = TemporaryFolder()
    private val own = fp(1)
    private val peer = fp(2)
    private val foreign = fp(3)
    private fun fp(seed: Int) = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { seed.toByte() })
    private fun store(name: String = "bindings", ownFP: String = own) = BindingStore(File(folder.root, name), ownFP)
    private fun frame(method: String, path: String, value: Any? = null, token: String? = null): Frame {
        val bytes = ByteArrayOutputStream()
        Wire.write(bytes, "$method $path HTTP/1.1", value?.let(Json::bytes) ?: byteArrayOf(), mapOf("x-limlink-app" to "limlink") + (token?.let { mapOf("x-limlink-pair-token" to it) } ?: emptyMap()))
        return Wire.read(ByteArrayInputStream(bytes.toByteArray()))
    }
    private fun start(request: String = UUID.randomUUID().toString(), name: String = "Caller") = frame("POST", "${Limits.PREFIX}/pair/start", mapOf("version" to 1, "requestId" to request, "alias" to name, "deviceType" to "mac"))
    private fun receiver(service: BindingService, peerFP: String = peer, offered: (Offer) -> Unit = {}) = ReceiverConnection(
        File(folder.root, "staging"), { "Android" }, 1234,
        { offered(it); CompletableFuture.completedFuture(it.automatic) }, { error("unused") },
        peerFingerprint = peerFP, binding = service)
    private fun pairPath(start: Frame) = "${Limits.PREFIX}/pair/${Json.text(start.json, "pairId")}"
    private fun token(start: Frame) = Json.text(start.json, "token")
    private fun complete(receiver: ReceiverConnection, start: Frame) = receiver.handle(frame("POST", "${pairPath(start)}/complete", emptyMap<String, String>(), token(start)))

    @Test fun controlStartIsAvailableBeforeFileHello() {
        val service = BindingService(store(), { "Android" })
        receiver(service).use { receiver -> assertEquals(202, receiver.handle(start()).status) }
    }
    @Test fun initiatorGrantDoesNotPersistUntilResponderAcceptsAndCompletes() {
        val store = store(); var prompt: BindingPrompt? = null
        val service = BindingService(store, { "Android" }, { prompt = it })
        receiver(service).use { receiver ->
            val start = receiver.handle(start()); assertEquals(peer, prompt!!.peerFP)
            assertNull(store.active(peer)); assertEquals(409, complete(receiver, start).status)
            service.decide(Json.text(start.json, "pairId"), true)
            assertNull(store.active(peer)); assertEquals(200, complete(receiver, start).status)
            assertEquals(Json.text(start.json, "pairId"), store.active(peer)!!.bindingId)
        }
    }
    @Test fun wrongConnectionWrongActualIdentityAndWrongTokenCannotComplete() {
        val service = BindingService(store(), { "Android" })
        receiver(service).use { owner -> receiver(service).use { other -> receiver(service, foreign).use { foreign ->
            val start = owner.handle(start()); service.decide(Json.text(start.json, "pairId"), true)
            assertEquals(403, complete(other, start).status)
            assertEquals(403, complete(foreign, start).status)
            assertEquals(403, owner.handle(frame("POST", "${pairPath(start)}/complete", emptyMap<String,String>(), "wrong")).status)
            assertEquals(200, complete(owner, start).status)
        } } }
    }
    @Test fun sameRequestIsIdempotentButOtherRequestIsBusy() {
        val service = BindingService(store(), { "Android" }); val request = UUID.randomUUID().toString()
        receiver(service).use { receiver ->
            val first = receiver.handle(start(request)); val again = receiver.handle(start(request))
            assertEquals(token(first), token(again)); assertEquals(pairPath(first), pairPath(again))
            assertEquals(409, receiver.handle(start()).status)
        }
    }
    @Test fun rejectedDisconnectedAndExpiredAttemptsNeverPersist() {
        for (mode in listOf("reject", "disconnect", "expire")) {
            var now = 0L; val store = store(mode)
            val service = BindingService(store, { "Android" }, nanoTime = { now })
            val receiver = receiver(service); val start = receiver.handle(start())
            when (mode) {
                "reject" -> service.decide(Json.text(start.json, "pairId"), false)
                "disconnect" -> { service.decide(Json.text(start.json, "pairId"), true); receiver.close() }
                else -> { now = 120_000_000_000L; service.decide(Json.text(start.json, "pairId"), true) }
            }
            assertTrue(complete(receiver, start).status >= 400); assertNull(store.active(peer)); receiver.close()
        }
    }
    @Test fun pollsDoNotExtendFixedMonotonicDeadline() {
        var now = 0L; val service = BindingService(store(), { "Android" }, nanoTime = { now })
        receiver(service).use { receiver ->
            val start = receiver.handle(start()); now = 119_000_000_000L
            assertEquals(1L, Json.long(receiver.handle(frame("GET", pairPath(start), token = token(start))).json, "expiresInSeconds"))
            now = 120_000_000_000L
            assertEquals(410, receiver.handle(frame("GET", pairPath(start), token = token(start))).status)
        }
    }
    @Test fun cancellationAndRevocationPreventDuplicateCompleteResurrection() {
        for (operation in listOf("cancel", "revoke")) {
            val store = store(operation); val service = BindingService(store, { "Android" })
            receiver(service).use { receiver ->
                val start = receiver.handle(start()); service.decide(Json.text(start.json, "pairId"), true)
                assertEquals(200, complete(receiver, start).status); assertEquals(200, complete(receiver, start).status)
                assertEquals(200, receiver.handle(frame("POST", "${pairPath(start)}/$operation", emptyMap<String,String>(), if (operation == "cancel") token(start) else null)).status)
                assertNull(store.active(peer)); assertEquals(409, complete(receiver, start).status)
            }
        }
    }
    @Test fun cancellationCannotRemoveNewerRelationship() {
        val store = store(); val service = BindingService(store, { "Android" })
        receiver(service).use { receiver ->
            val start = receiver.handle(start()); service.decide(Json.text(start.json, "pairId"), true); complete(receiver, start)
            val newer = UUID.randomUUID().toString(); store.put(DeviceBinding(own, peer, newer, "New name", "mac", 0))
            receiver.handle(frame("POST", "${pairPath(start)}/cancel", emptyMap<String,String>(), token(start)))
            assertEquals(newer, store.active(peer)!!.bindingId)
        }
    }
    @Test fun localUnbindCancelsAcceptedReplacementForTheSamePeer() {
        val store = store(); val oldId = UUID.randomUUID().toString()
        store.put(DeviceBinding(own, peer, oldId, "Mac", "mac", 0))
        val service = BindingService(store, { "Android" })
        receiver(service).use { receiver ->
            val replacement = receiver.handle(start())
            service.decide(Json.text(replacement.json, "pairId"), true)
            service.unbind(peer, oldId)
            assertEquals(409, complete(receiver, replacement).status)
            assertNull(store.active(peer))
            assertNull(store().active(peer))
        }
    }

    @Test fun staleLocalUnbindRemovesAnAlreadyCompletedReplacement() {
        val store = store(); val oldId = UUID.randomUUID().toString()
        store.put(DeviceBinding(own, peer, oldId, "Mac", "mac", 0))
        val service = BindingService(store, { "Android" })
        receiver(service).use { receiver ->
            val replacement = receiver.handle(start())
            val newId = Json.text(replacement.json, "pairId")
            service.decide(newId, true)
            assertEquals(200, complete(receiver, replacement).status)
            assertTrue(store.authorizes(peer, newId))
            service.unbind(peer, oldId)
            assertNull(store.active(peer))
            assertNull(store().active(peer))
            assertEquals(409, complete(receiver, replacement).status)
        }
    }

    @Test fun staleRemoteRevokeCannotCancelAcceptedReplacement() {
        val store = store(); val oldId = UUID.randomUUID().toString()
        store.put(DeviceBinding(own, peer, oldId, "Mac", "mac", 0))
        val service = BindingService(store, { "Android" })
        receiver(service).use { receiver ->
            val replacement = receiver.handle(start())
            val newId = Json.text(replacement.json, "pairId")
            service.decide(newId, true)
            assertEquals(200, receiver.handle(frame("POST", "${Limits.PREFIX}/pair/$oldId/revoke", emptyMap<String,String>())).status)
            assertEquals(200, complete(receiver, replacement).status)
            assertTrue(store.authorizes(peer, newId))
        }
    }

    @Test fun storageFailureReturnsFailureAndCannotAuthorize() {
        val broken = object : BindingStore(File(folder.root, "broken"), own) { override fun persist(bytes: ByteArray) { throw java.io.IOException("disk full") } }
        val service = BindingService(broken, { "Android" })
        receiver(service).use { receiver ->
            val start = receiver.handle(start()); service.decide(Json.text(start.json, "pairId"), true)
            assertEquals(500, complete(receiver, start).status); assertNull(broken.active(peer)); assertNotNull(broken.error)
        }
    }
    @Test fun reloadOwnKeyChangeAndCorruptionFailClosed() {
        val id = UUID.randomUUID().toString(); val store = store(); store.put(DeviceBinding(own, peer, id, "Mac", "mac", 1))
        assertTrue(store().authorizes(peer, id)); assertFalse(store(ownFP = foreign).authorizes(peer, id))
        File(folder.root, "bindings").writeText("{corrupted")
        assertFalse(store().authorizes(peer, id)); assertNotNull(store().error)
    }
    @Test fun onlyThisHelloMatchingActualIdentityAndCurrentStoreAutoReceives() {
        val id = UUID.randomUUID().toString(); val store = store(); store.put(DeviceBinding(own, peer, id, "Alias is display only", "mac", 0))
        val service = BindingService(store, { "Android" })
        for ((actual, claim, expected) in listOf(Triple(peer, id, true), Triple(peer, null, false), Triple(foreign, id, false), Triple(peer, UUID.randomUUID().toString(), false))) {
            var offer: Offer? = null
            receiver(service, actual) { offer = it }.use { receiver ->
                assertEquals(200, receiver.handle(frame("POST", "${Limits.PREFIX}/hello", mapOf("app" to "limlink", "proto" to listOf("1.0"), "alias" to "Same name") + (claim?.let { mapOf("bindingId" to it) } ?: emptyMap()))).status)
                val created = receiver.handle(frame("POST", "${Limits.PREFIX}/sessions", mapOf("transport" to "lan", "clientSessionKey" to "key", "totalEntries" to 1, "totalBytes" to 0, "entries" to listOf(mapOf("id" to "file", "kind" to "file", "relativePath" to "empty", "size" to 0)))))
                assertEquals(202, created.status); assertEquals(expected, offer!!.automatic); assertEquals(actual, offer!!.peerFingerprint)
            }
        }
    }
    @Test fun unbindAfterHelloForcesConsentForOfferOnExistingConnection() {
        val id = UUID.randomUUID().toString(); val store = store(); store.put(DeviceBinding(own, peer, id, "Mac", "mac", 0)); val service = BindingService(store, { "Android" })
        var automatic = true
        receiver(service) { automatic = it.automatic }.use { receiver ->
            receiver.handle(frame("POST", "${Limits.PREFIX}/hello", mapOf("app" to "limlink", "proto" to listOf("1.0"), "alias" to "Mac", "bindingId" to id)))
            service.unbind(peer)
            receiver.handle(frame("POST", "${Limits.PREFIX}/sessions", mapOf("transport" to "lan", "clientSessionKey" to "key", "totalEntries" to 1, "totalBytes" to 0, "entries" to listOf(mapOf("id" to "file", "kind" to "file", "relativePath" to "empty", "size" to 0)))))
            assertFalse(automatic)
        }
    }
    @Test fun rateLimitIsGlobalAndAuthenticatedRetriesDoNotConsumeSlots() {
        val service = BindingService(store(), { "Android" })
        repeat(3) { receiver(service).use { receiver ->
            val request = UUID.randomUUID().toString(); val start = receiver.handle(start(request))
            assertEquals(202, start.status); assertEquals(202, receiver.handle(start(request)).status)
            service.decide(Json.text(start.json, "pairId"), false)
        } }
        receiver(service).use { assertEquals(429, it.handle(start()).status) }
    }
    @Test fun invalidVersionUuidAliasSelfAndAppAreRejected() {
        val service = BindingService(store(), { "Android" })
        receiver(service).use { receiver ->
            assertEquals(400, receiver.handle(start("UPPER-NOT-UUID")).status)
            assertEquals(400, receiver.handle(start(name = "a\nb")).status)
            assertEquals(400, receiver.handle(frame("POST", "${Limits.PREFIX}/pair/start", mapOf("version" to 1.0))).status)
            assertEquals(400, receiver.handle(start().copy(headers = mapOf("x-limlink-app" to "other"))).status)
        }
        receiver(service, own).use { assertEquals(400, it.handle(start()).status) }
    }
    @Test fun initiatingClientUsesActualControlRoutesAndPersistsOnlyCompletedRelation() {
        val responderStore = store("responder", peer); var prompt: BindingPrompt? = null
        val responder = BindingService(responderStore, { "Responder" }, { prompt = it })
        val callerStore = store("caller"); val caller = BindingService(callerStore, { "Caller" }); val owner = Any()
        caller.beginOutgoing(owner, peer)
        receiver(responder, own).use { remote ->
            val client = BindingClient(caller, Exchange { method, path, body, headers -> remote.handle(Frame("$method $path HTTP/1.1", mapOf("x-limlink-app" to "limlink") + headers, body)) }, peer,
                wait = { assertNull(callerStore.active(peer)); responder.decide(prompt!!.pairId, true) })
            val result = client.bind(owner, "Caller")
            assertEquals(result.bindingId, responderStore.active(own)!!.bindingId)
            assertEquals(result.bindingId, callerStore.active(peer)!!.bindingId)
        }
    }
    @Test fun localWriteFailureBestEffortCancelsRemoteCompletedRecord() {
        val responderStore = store("responder", peer); var prompt: BindingPrompt? = null
        val responder = BindingService(responderStore, { "Responder" }, { prompt = it })
        val broken = object : BindingStore(File(folder.root, "broken"), own) { override fun persist(bytes: ByteArray) { error("disk full") } }
        val caller = BindingService(broken, { "Caller" }); val owner = Any(); caller.beginOutgoing(owner, peer)
        receiver(responder, own).use { remote ->
            val client = BindingClient(caller, Exchange { method, path, body, headers -> remote.handle(Frame("$method $path HTTP/1.1", mapOf("x-limlink-app" to "limlink") + headers, body)) }, peer, wait = { responder.decide(prompt!!.pairId, true) })
            assertThrows(Exception::class.java) { client.bind(owner, "Caller") }
            assertNull(broken.active(peer)); assertNull(responderStore.active(own))
        }
    }
    @Test fun localUnbindInvalidatesLateOutgoingCompletion() {
        val store = store(); val service = BindingService(store, { "Caller" }); val owner = Any(); service.beginOutgoing(owner, peer)
        service.unbind(peer)
        assertThrows(Exception::class.java) { service.saveOutgoing(owner, DeviceBinding(own, peer, UUID.randomUUID().toString(), "Peer", "mac", 0)) }
        assertNull(store.active(peer))
    }
    @Test fun appStopInvalidatesPendingUiAndLateAccept() {
        val store = store(); val service = BindingService(store, { "Android" })
        receiver(service).use { receiver ->
            val start = receiver.handle(start()); service.close(); service.decide(Json.text(start.json, "pairId"), true)
            assertTrue(complete(receiver, start).status >= 400); assertNull(store.active(peer))
        }
    }
    @Test fun lostCompleteResponseCannotGiveCallerAutomaticReceivePermission() {
        val responderStore = store("responder", peer); var prompt: BindingPrompt? = null
        val responder = BindingService(responderStore, { "Responder" }, { prompt = it })
        val callerStore = store("caller"); val caller = BindingService(callerStore, { "Caller" }); val owner = Any(); caller.beginOutgoing(owner, peer)
        receiver(responder, own).use { remote ->
            val client = BindingClient(caller, Exchange { method, path, body, headers ->
                if (path.endsWith("/cancel")) throw java.io.IOException("disconnected")
                val response = remote.handle(Frame("$method $path HTTP/1.1", mapOf("x-limlink-app" to "limlink") + headers, body))
                if (path.endsWith("/complete")) throw java.io.IOException("lost completed response")
                response
            }, peer, wait = { responder.decide(prompt!!.pairId, true) })
            assertThrows(Exception::class.java) { client.bind(owner, "Caller") }
            assertNull(callerStore.active(peer)); assertNotNull(responderStore.active(own))
            assertFalse(responderStore.authorizes(own, callerStore.active(peer)?.bindingId))
        }
    }
    @Test fun revokeFromForeignKeyDoesNotRemoveRelationship() {
        val id = UUID.randomUUID().toString(); val store = store(); store.put(DeviceBinding(own, peer, id, "Mac", "mac", 0)); val service = BindingService(store, { "Android" })
        receiver(service, foreign).use { remote -> assertEquals(200, remote.handle(frame("POST", "${Limits.PREFIX}/pair/$id/revoke", emptyMap<String,String>())).status) }
        assertTrue(store.authorizes(peer, id))
    }
    @Test fun controlFramingRejectsOversizeBeforeAllocatingBody() {
        val raw = "POST /limlink/v1/pair/start HTTP/1.1\r\ncontent-length: 16385\r\n\r\n"
        assertThrows(IllegalArgumentException::class.java) { Wire.read(raw.byteInputStream()) }
    }

    @Test fun sameConnectionOwnerStillCannotImpersonateAnotherActualTlsKey() {
        val service = BindingService(store(), { "Android" }); val owner = Any()
        val start = service.route(owner, peer, start()); service.decide(Json.text(start.json, "pairId"), true)
        val request = frame("POST", "${pairPath(start)}/complete", emptyMap<String,String>(), token(start))
        assertEquals(403, service.route(owner, foreign, request).status)
        assertEquals(200, service.route(owner, peer, request).status)
    }
    @Test fun remoteCannotCallResponderAcceptRoute() {
        val store = store(); val service = BindingService(store, { "Android" })
        receiver(service).use { remote ->
            val start = remote.handle(start())
            assertEquals(400, remote.handle(frame("POST", "${pairPath(start)}/accept", emptyMap<String,String>(), token(start))).status)
            assertEquals(409, complete(remote, start).status); assertNull(store.active(peer))
        }
    }
    @Test fun deviceNameKeepsCanonicalWholeUnicodeWithinWireByteLimit() {
        val result = BindingValidation.deviceName(" e\u0301" + "界".repeat(40) + "\n")
        assertEquals(result, BindingValidation.alias(result)); assertTrue(result.startsWith("é")); assertTrue(result.toByteArray().size <= 63)
    }
    @Test fun cancelDuringLocalDurableWriteCannotLeaveActivePermission() {
        var current = true
        val store = object : BindingStore(File(folder.root, "cancel-write"), own) {
            override fun persist(bytes: ByteArray) { super.persist(bytes); current = false }
        }
        val service = BindingService(store, { "Caller" }); val owner = Any(); service.beginOutgoing(owner, peer)
        val record = DeviceBinding(own, peer, UUID.randomUUID().toString(), "Peer", "mac", 0)
        assertThrows(Exception::class.java) { service.saveOutgoing(owner, record) { current } }
        assertNull(store.active(peer)); assertNull(BindingStore(File(folder.root, "cancel-write"), own).active(peer))
    }

    @Test fun fileCancelLeavesUnrelatedDispatchedPairSocketAndAttemptAlive() {
        val service = BindingService(store(), { "Android" })
        receiver(service).use { pair -> receiver(service).use { file ->
            val start = pair.handle(start())
            file.handle(frame("POST", "${Limits.PREFIX}/hello", mapOf("app" to "limlink", "proto" to listOf("1.0"), "alias" to "Mac")))
            java.net.Socket().use { pairSocket -> java.net.Socket().use { fileSocket ->
                cancelFileConnections(mapOf(pairSocket to pair, fileSocket to file))
                assertFalse(pairSocket.isClosed); assertTrue(fileSocket.isClosed)
                service.decide(Json.text(start.json, "pairId"), true)
                assertEquals(200, complete(pair, start).status)
            } }
        } }
    }
    @Test fun clientControlResponseFramingRejectsOversizeBeforeReadingPayload() {
        val raw = "HTTP/1.1 200 OK\r\ncontent-length: 16385\r\n\r\n"
        assertThrows(IllegalArgumentException::class.java) { Wire.read(raw.byteInputStream(), 16_384) }
    }

    @Test fun boundKeyCannotAuthorizeAFileFromAnotherApp() {
        val id = UUID.randomUUID().toString()
        val store = store(); store.put(DeviceBinding(own, peer, id, "Mac", "mac", 0))
        val service = BindingService(store, { "Android" })
        var offers = 0
        receiver(service) { offers++ }.use { receiver ->
            val hello = frame("POST", "${Limits.PREFIX}/hello", mapOf(
                "app" to "casecheck", "proto" to listOf("1.0"), "alias" to "Mac", "bindingId" to id,
            ))
            val response = receiver.handle(hello)
            assertEquals(400, response.status)
            assertEquals("E_APP_MISMATCH", Json.text(response.json, "code"))
            val offer = frame("POST", "${Limits.PREFIX}/sessions", mapOf(
                "transport" to "lan", "clientSessionKey" to "foreign-app", "totalEntries" to 1, "totalBytes" to 0,
                "entries" to listOf(mapOf("id" to "file", "kind" to "file", "relativePath" to "empty", "size" to 0)),
            ))
            val rejected = receiver.handle(offer)
            assertEquals(409, rejected.status)
            assertEquals("E_INVALID_STATE", Json.text(rejected.json, "code"))
            assertEquals(0, offers)
        }
    }

}
