package com.limlink.app.preview

interface PhotoRecoveryBackend {
    fun find(key: String): PhotoRecord?
    fun discard(uri: String)
    fun settle(key: String, publishedUri: String?)
}

/** Recovery never creates/copies assets and only visits attempts enrolled before MediaStore insert. */
object PhotoRecovery {
    fun reconcile(enrolled: List<String>, backend: PhotoRecoveryBackend) {
        for (key in enrolled.distinct()) {
            val publishedUri = try {
                val row = backend.find(key)
                if (row != null && !row.published) backend.discard(row.uri)
                row?.takeIf { it.published }?.uri
            } catch (_: Exception) { null }
            backend.settle(key, publishedUri)
        }
    }
}
