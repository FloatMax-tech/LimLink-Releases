package com.limlink.app.preview

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PhotoAttemptJournalTest {
    @Test fun deletingReceiptThenRestartingDoesNotRestoreFailedExportOrDeleteGalleryAsset() {
        val directory = Files.createTempDirectory("limlink-delete-recovery").toFile()
        try {
        val original = File(directory, "received.jpg").apply { writeText("verified image bytes") }
        val gallery = File(directory, "gallery.jpg").apply { writeText("verified image bytes") }
        val disk = mutableMapOf<String, String>()
        fun journal() = PhotoAttemptJournal({ disk.toMap() }) { key, value ->
            if (value == null) disk.remove(key) else disk[key] = value
            true
        }
        journal().enroll("deleted-receipt", "failed-original-metadata")
        journal().enroll("kept-receipt", "kept-original-metadata")
        disk["deleted-receipt"] = gallery.toURI().toString()
        assertTrue(original.delete())
        journal().forget("deleted-receipt")

        val restored = journal().enrolled()
        val recovered = mutableListOf<String>()
        val deletedAssets = mutableListOf<String>()
        PhotoRecovery.reconcile(restored.keys.toList(), object : PhotoRecoveryBackend {
            override fun find(key: String): PhotoRecord? = null
            override fun discard(uri: String) { deletedAssets += uri }
            override fun settle(key: String, publishedUri: String?) { recovered += key }
        })
        assertEquals(listOf("kept-receipt"), recovered)
        assertFalse(original.exists())
        assertEquals(gallery.toURI().toString(), disk["deleted-receipt"])
        assertEquals("verified image bytes", gallery.readText())
        assertTrue(deletedAssets.isEmpty())
        } finally { directory.deleteRecursively() }
    }
}
