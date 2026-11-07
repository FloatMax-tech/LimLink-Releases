package com.limlink.app.preview

import org.junit.Assert.*
import org.junit.Test

class PhotoRecoveryTest {
    private class Backend(private val rows: MutableMap<String, PhotoRecord>) : PhotoRecoveryBackend {
        val discarded = mutableListOf<String>()
        val completed = mutableListOf<Pair<String, String?>>()
        override fun find(key: String) = rows[key]
        override fun discard(uri: String) { discarded += uri }
        override fun settle(key: String, publishedUri: String?) { completed += key to publishedUri }
    }

    @Test fun recoveryOnlyTouchesEnrolledAttemptsAndNeverCopiesHistoricalFiles() {
        val backend = Backend(mutableMapOf("requested" to PhotoRecord("pending", false), "historical" to PhotoRecord("untouched", false)))
        PhotoRecovery.reconcile(listOf("requested"), backend)
        assertEquals(listOf("pending"), backend.discarded)
        assertEquals(listOf("requested" to null), backend.completed)
    }

    @Test fun crashAfterPublicationSettlesWithoutDuplicateAssetOrSourceRead() {
        val backend = Backend(mutableMapOf("requested" to PhotoRecord("saved", true)))
        PhotoRecovery.reconcile(listOf("requested"), backend)
        assertTrue(backend.discarded.isEmpty())
        assertEquals(listOf("requested" to "saved"), backend.completed)
    }
}
