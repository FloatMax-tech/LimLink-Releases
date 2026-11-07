package com.limlink.app.preview

import org.junit.Assert.*
import org.junit.Test

class PhotoExportGateTest {
    private class Store : PhotoExportBackend {
        var record: PhotoRecord? = null
        var inserts = 0
        var copies = 0
        var discards = 0
        var copyFails = false
        override fun find(key: String) = record
        override fun create(key: String): String { inserts++; return "content://images/$inserts".also { record = PhotoRecord(it, false) } }
        override fun copyTo(uri: String) { copies++; if (copyFails) error("permission revoked") }
        override fun publish(uri: String) { record = PhotoRecord(uri, true) }
        override fun discard(uri: String) { discards++; record = null }
    }

    @Test fun repeatedAndRestartedExportsReusePublishedAsset() {
        val store = Store()
        assertEquals(PhotoExportGate().export("received-1", store), PhotoExportGate().export("received-1", store))
        assertEquals(1, store.inserts)
        assertEquals(1, store.copies)
    }

    @Test fun failureDiscardsOnlyAlbumCopyAndAllowsRetry() {
        val store = Store().apply { copyFails = true }
        assertThrows(IllegalStateException::class.java) { PhotoExportGate().export("received-1", store) }
        assertEquals(1, store.discards)
        store.copyFails = false
        assertEquals("content://images/2", PhotoExportGate().export("received-1", store))
    }

    @Test fun interruptedPendingAssetIsNeverTreatedAsVerified() {
        val store = Store().apply { record = PhotoRecord("content://images/interrupted", false) }
        PhotoExportGate().export("received-1", store)
        assertEquals(1, store.discards)
        assertEquals(1, store.copies)
        assertTrue(store.record!!.published)
    }

    @Test fun savedGalleryAssetRemainsUsableAfterOriginalSourceDisappears() {
        val store = Store().apply { record = PhotoRecord("content://images/already-saved", true); copyFails = true }
        assertEquals("content://images/already-saved", PhotoExportGate().export("received-1", store))
        assertEquals(0, store.inserts)
        assertEquals(0, store.copies)
    }
}
