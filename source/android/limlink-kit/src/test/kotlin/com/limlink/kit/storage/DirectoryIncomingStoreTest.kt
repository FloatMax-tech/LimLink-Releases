package com.limlink.kit.storage

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class DirectoryIncomingStoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun publishWritesTheSampleAndRemovesThePendingFile() {
        val store = DirectoryIncomingStore(folder.root)
        val pending = store.begin(SamplePayload.FILE_NAME, SamplePayload.MIME)
        assertFalse(File(folder.root, SamplePayload.FILE_NAME).exists())
        assertTrue(File(pending.locator).isFile)

        store.write(pending, SamplePayload.bytes.copyOfRange(0, 4))
        store.write(pending, SamplePayload.bytes.copyOfRange(4, SamplePayload.bytes.size))
        val published = store.publish(pending)

        assertEquals(SamplePayload.FILE_NAME, published.displayName)
        assertArrayEquals(SamplePayload.bytes, File(published.locator).readBytes())
        assertFalse(File(pending.locator).exists())
    }

    @Test
    fun secondSampleGetsANumericSuffix() {
        val store = DirectoryIncomingStore(folder.root)
        val first = SamplePayload.write(store)
        val second = SamplePayload.write(store)
        assertEquals("limlink-sample.txt", first.displayName)
        assertEquals("limlink-sample (1).txt", second.displayName)
        assertArrayEquals(SamplePayload.bytes, File(second.locator).readBytes())
        assertTrue(File(first.locator).exists())
    }

    @Test
    fun discardDoesNotPublish() {
        val store = DirectoryIncomingStore(folder.root)
        val pending = store.begin("draft.txt", "text/plain")
        store.write(pending, "nope".encodeToByteArray())
        store.discard(pending)
        assertFalse(File(folder.root, "draft.txt").exists())
        assertFalse(File(pending.locator).exists())
    }

    @Test
    fun publishDoesNotOverwriteAFileThatAppearedLater() {
        val store = DirectoryIncomingStore(folder.root)
        val pending = store.begin("report.txt", "text/plain")
        store.write(pending, "new".encodeToByteArray())
        File(folder.root, "report.txt").writeText("old")
        val published = store.publish(pending)
        assertEquals("report (1).txt", published.displayName)
        assertEquals("old", File(folder.root, "report.txt").readText())
        assertEquals("new", File(published.locator).readText())
    }
}
