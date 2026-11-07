package com.limlink.kit.lan

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class SnapshotLeaseTest {
    @Test fun previewLeaseSurvivesSelectionReplacementAndClosesExactlyOnce() {
        val directory = Files.createTempDirectory("limlink-lease").toFile()
        try {
            val snapshot = Snapshot.capture("original".byteInputStream(), "photo.jpg", directory)
            val lease = requireNotNull(snapshot.acquire())
            snapshot.close()
            snapshot.close()
            assertTrue(lease.file.exists())
            assertEquals("original", lease.file.readText())
            assertNull(snapshot.acquire())
            lease.close()
            lease.close()
            assertFalse(lease.file.exists())
        } finally { directory.deleteRecursively() }
    }
}
