package com.limlink.kit.lan

import com.limlink.kit.storage.DirectoryIncomingStore
import com.limlink.kit.storage.IncomingStore
import com.limlink.kit.storage.PendingFile
import com.limlink.kit.storage.PublishedFile
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CompletableFuture

class FileTransferTest {
    @get:Rule val folder = TemporaryFolder()
    private fun frame(method: String, path: String, value: Any? = null, headers: Map<String,String> = emptyMap(), bytes: ByteArray? = null) =
        Frame("$method $path HTTP/1.1", mapOf("x-limlink-app" to "limlink") + headers, bytes ?: value?.let(Json::bytes) ?: byteArrayOf())
    private fun hello(receiver: ReceiverConnection, name: String = "Sender name") = receiver.handle(frame("POST", "${Limits.PREFIX}/hello", mapOf("app" to "limlink", "proto" to listOf("1.0"), "alias" to name)))
    private fun create(receiver: ReceiverConnection, size: Any = 3L, name: String = "note.txt"): Frame = receiver.handle(frame("POST", "${Limits.PREFIX}/sessions", mapOf("clientSessionKey" to "key", "transport" to "lan", "totalEntries" to 1, "totalBytes" to size, "entries" to listOf(mapOf("id" to "file", "kind" to "file", "size" to size, "relativePath" to name)))))
    private fun receiver(decision: CompletableFuture<Boolean> = CompletableFuture.completedFuture(true), offered: (Offer) -> Unit = {}, store: IncomingStore = DirectoryIncomingStore(File(folder.root, "published")), clock: () -> Long = System::nanoTime, completed: (Offer, PublishedFile) -> Unit = { _, _ -> }) =
        ReceiverConnection(File(folder.root, "staging"), { "Android receiver" }, 1234, { offered(it); decision }, { store }, completed = completed, nanoTime = clock)
    private fun base(created: Frame) = "${Limits.PREFIX}/sessions/${Json.text(created.json, "sessionId")}"
    private fun token(receiver: ReceiverConnection, base: String): String = Json.text(receiver.handle(frame("GET", base)).json.getAsJsonObject("files").getAsJsonObject("file"), "token")
    private fun put(receiver: ReceiverConnection, base: String, token: String, offset: String = "0", bytes: ByteArray = "abc".toByteArray()) = receiver.handle(frame("PUT", "$base/files/file", headers = mapOf("x-limlink-token" to token, "x-limlink-offset" to offset, "content-type" to "application/octet-stream"), bytes = bytes))

    @Test fun malformedJsonIsRejectedAsBadRequest() {
        receiver().use { receiver ->
            val response = receiver.handle(frame("POST", "${Limits.PREFIX}/hello", bytes = "{broken".toByteArray()))
            assertEquals(400, response.status)
            assertEquals("E_BAD_REQUEST", Json.text(response.json, "code"))
        }
    }
    @Test fun consentBindsTheHelloNameAndBlocksContent() {
        val pending = CompletableFuture<Boolean>()
        var offered: Offer? = null
        receiver(pending, { offered = it }).use { receiver ->
            assertEquals(200, hello(receiver, "Living room iPad").status)
            val base = base(create(receiver))
            assertEquals("Living room iPad", offered?.senderName)
            assertEquals(409, put(receiver, base, "fake").status)
            assertEquals(0L, File(folder.root, "staging").listFiles()!!.single().length())
            pending.complete(false)
            assertEquals(403, receiver.handle(frame("GET", base)).status)
        }
        assertTrue(File(folder.root, "staging").listFiles()!!.isEmpty())
    }
    @Test fun foreignConnectionAndWrongTokenOrOffsetCannotWrite() {
        receiver().use { owner -> receiver().use { foreign ->
            hello(owner); hello(foreign)
            val base = base(create(owner)); val token = token(owner, base)
            assertEquals(404, put(foreign, base, token).status)
            assertEquals(403, put(owner, base, "wrong").status)
            assertEquals(409, put(owner, base, token, "1").status)
            assertEquals(409, put(owner, base, token, "+0").status)
            assertEquals(200, put(owner, base, token).status)
            assertEquals(409, put(owner, base, token).status)
        } }
    }
    @Test fun completeIsRequiredBeforeAnyFinalFileAppears() {
        receiver().use { receiver ->
            hello(receiver); val base = base(create(receiver)); val token = token(receiver, base)
            put(receiver, base, token)
            assertFalse(File(folder.root, "published/note.txt").exists())
            assertEquals(409, receiver.handle(frame("POST", "$base/finish")).status)
            val digest = java.security.MessageDigest.getInstance("SHA-256").digest("abc".toByteArray()).hex()
            val complete = receiver.handle(frame("POST", "$base/files/file/complete", mapOf("sha256" to digest)))
            assertEquals(200, complete.status)
            assertEquals("abc", File(folder.root, "published/note.txt").readText())
            val finish = receiver.handle(frame("POST", "$base/finish"))
            assertEquals("finished", Json.text(finish.json, "state"))
        }
    }
    @Test fun completionEventIsAfterPublicationAndNeverOnlyFullByteCount() {
        val events = mutableListOf<PublishedFile>()
        receiver(completed = { _, file ->
            assertEquals("abc", File(file.locator).readText())
            events += file
        }).use { receiver ->
            hello(receiver); val base = base(create(receiver)); put(receiver, base, token(receiver, base))
            assertTrue(events.isEmpty())
            assertEquals(422, receiver.handle(frame("POST", "$base/files/file/complete", mapOf("sha256" to "0".repeat(64)))).status)
            assertTrue(events.isEmpty())
            put(receiver, base, token(receiver, base))
            val digest = java.security.MessageDigest.getInstance("SHA-256").digest("abc".toByteArray()).hex()
            assertEquals(200, receiver.handle(frame("POST", "$base/files/file/complete", mapOf("sha256" to digest))).status)
            assertEquals(1, events.size)
            receiver.handle(frame("POST", "$base/finish"))
            assertEquals(1, events.size)
        }
    }
    @Test fun checksumMismatchResetsAndDisconnectCleansStaging() {
        receiver().use { receiver ->
            hello(receiver); val base = base(create(receiver)); val token = token(receiver, base)
            put(receiver, base, token)
            assertEquals(422, receiver.handle(frame("POST", "$base/files/file/complete", mapOf("sha256" to "0".repeat(64)))).status)
            assertEquals(0L, File(folder.root, "staging").listFiles()!!.single().length())
        }
        assertTrue(File(folder.root, "staging").listFiles()!!.isEmpty())
        assertFalse(File(folder.root, "published/note.txt").exists())
    }
    @Test fun acceptsFiveGigabyteMetadataWithoutAllocatingPayloadAndRejectsLarger() {
        receiver().use { receiver -> hello(receiver); assertEquals(202, create(receiver, 5_000_000_000L).status) }
        receiver().use { receiver -> hello(receiver); assertEquals(413, create(receiver, 5_000_000_001L).status) }
        assertTrue(File(folder.root, "staging").listFiles()!!.isEmpty())
    }
    @Test fun rejectsFractionalStringBooleanSizesAndUnsafeNames() {
        for (size in listOf<Any>("3", true, 3.1, -1L)) receiver().use { receiver -> hello(receiver); assertEquals(400, create(receiver, size).status) }
        for (name in listOf("../escape", "dir/file", "dir\\file")) receiver().use { receiver -> hello(receiver); assertEquals(400, create(receiver, name = name).status) }
    }
    @Test fun approvalDeadlineDoesNotResetOnPoll() {
        var time = 0L
        receiver(CompletableFuture(), clock = { time }).use { receiver ->
            hello(receiver); val base = base(create(receiver))
            time = 120_000_000_000L
            assertTrue(receiver.approvalExpired())
            assertEquals(408, receiver.handle(frame("GET", base)).status)
        }
    }
    @Test fun diskPublicationFailureNeverReturnsSuccessAndDiscardsPending() {
        var discarded = false
        val failing = object : IncomingStore {
            override fun begin(desiredName: String, mimeType: String) = PendingFile("x", desiredName, "x")
            override fun write(pending: PendingFile, bytes: ByteArray) = Unit
            override fun publish(pending: PendingFile): PublishedFile = throw java.io.IOException("disk full")
            override fun discard(pending: PendingFile) { discarded = true }
        }
        receiver(store = failing).use { receiver ->
            hello(receiver); val base = base(create(receiver)); put(receiver, base, token(receiver, base))
            val digest = java.security.MessageDigest.getInstance("SHA-256").digest("abc".toByteArray()).hex()
            assertEquals(500, receiver.handle(frame("POST", "$base/files/file/complete", mapOf("sha256" to digest))).status)
            assertTrue(discarded)
        }
    }
    @Test fun localCancellationDuringPublicationDiscardsWithoutPublishing() {
        lateinit var connection: ReceiverConnection
        var discarded = false
        var published = false
        val cancelling = object : IncomingStore {
            override fun begin(desiredName: String, mimeType: String) = PendingFile("x", desiredName, "x")
            override fun write(pending: PendingFile, bytes: ByteArray) { connection.close() }
            override fun publish(pending: PendingFile): PublishedFile {
                published = true
                return PublishedFile("note.txt", "x")
            }
            override fun discard(pending: PendingFile) { discarded = true }
        }
        connection = receiver(store = cancelling)
        connection.use { receiver ->
            hello(receiver); val base = base(create(receiver)); put(receiver, base, token(receiver, base))
            val digest = java.security.MessageDigest.getInstance("SHA-256").digest("abc".toByteArray()).hex()
            assertNotEquals(200, receiver.handle(frame("POST", "$base/files/file/complete", mapOf("sha256" to digest))).status)
            assertTrue(discarded)
            assertFalse(published)
            assertTrue(File(folder.root, "staging").listFiles()!!.isEmpty())
        }
    }
    @Test fun senderReceiverRoundTripIsChunkedAndNeverOverwrites() {
        val bytes = ByteArray(Limits.CHUNK + 19) { (it % 251).toByte() }
        val published = File(folder.root, "published").apply { mkdirs() }; File(published, "note.txt").writeText("original")
        var maximum = 0
        receiver().use { receiver ->
            Snapshot.capture(bytes.inputStream(), "note.txt", File(folder.root, "snapshots")).use { snapshot ->
                val name = FileSender(Exchange { method, path, body, headers ->
                    maximum = maxOf(maximum, body.size)
                    receiver.handle(frame(method, path, headers = headers, bytes = body))
                }).send(snapshot, "Mac", 7777)
                assertEquals("note (1).txt", name)
                assertArrayEquals(bytes, File(published, name).readBytes())
            }
        }
        assertEquals(Limits.CHUNK, maximum)
        assertEquals("original", File(published, "note.txt").readText())
        assertTrue(File(folder.root, "snapshots").listFiles()!!.isEmpty())
    }
    @Test fun emptyFilesTransferWithZeroLengthPut() {
        receiver().use { receiver ->
            Snapshot.capture(byteArrayOf().inputStream(), "empty", File(folder.root, "snapshots")).use { snapshot ->
                FileSender(Exchange { method, path, body, headers -> receiver.handle(frame(method, path, headers = headers, bytes = body)) }).send(snapshot, "Mac", 7777)
                assertEquals(0L, File(folder.root, "published/empty").length())
                assertTrue(File(folder.root, "published/empty").exists())
            }
        }
    }
    @Test fun senderRejectsAnInexactAcknowledgement() {
        receiver().use { receiver ->
            Snapshot.capture("abc".byteInputStream(), "note.txt", File(folder.root, "snapshots")).use { snapshot ->
                val sender = FileSender(Exchange { method, path, body, headers ->
                    val actual = receiver.handle(frame(method, path, headers = headers, bytes = body))
                    if (method == "PUT") Wire.response(200, mapOf("committedBytes" to 2)) else actual
                })
                assertThrows(Exception::class.java) { sender.send(snapshot, "Mac", 7777) }
            }
        }
        assertFalse(File(folder.root, "published/note.txt").exists())
    }
    @Test fun senderNeverReportsSuccessFromAnUnverifiedCompleteResponse() {
        receiver().use { receiver ->
            Snapshot.capture("abc".byteInputStream(), "note.txt", File(folder.root, "snapshots")).use { snapshot ->
                val sender = FileSender(Exchange { method, path, body, headers ->
                    val actual = receiver.handle(frame(method, path, headers = headers, bytes = body))
                    if (path.endsWith("/complete")) Wire.response(200, mapOf("verified" to false, "finalName" to "note.txt")) else actual
                })
                assertThrows(Exception::class.java) { sender.send(snapshot, "Mac", 7777) }
            }
        }
    }
    @Test fun senderRetriesChecksumMismatchOnceFromZero() {
        var completions = 0
        receiver().use { receiver ->
            Snapshot.capture("abc".byteInputStream(), "note.txt", File(folder.root, "snapshots")).use { snapshot ->
                val sender = FileSender(Exchange { method, path, body, headers ->
                    val payload = if (path.endsWith("/complete") && completions++ == 0) Json.bytes(mapOf("sha256" to "0".repeat(64))) else body
                    receiver.handle(frame(method, path, headers = headers, bytes = payload))
                })
                assertEquals("note.txt", sender.send(snapshot, "Mac", 7777))
            }
        }
        assertEquals(2, completions)
        assertEquals("abc", File(folder.root, "published/note.txt").readText())
    }
    @Test fun snapshotIsImmutableAndCancellationCleansIt() {
        val input = File(folder.root, "source").apply { writeText("original") }
        Snapshot.capture(input.inputStream(), "note", File(folder.root, "snapshots")).use { snapshot ->
            input.writeText("changed"); assertEquals("original", snapshot.file.readText())
        }
        assertThrows(Exception::class.java) { Snapshot.capture("abc".byteInputStream(), "cancel", File(folder.root, "snapshots")) { true } }
        assertTrue(File(folder.root, "snapshots").listFiles()!!.isEmpty())
    }
}
