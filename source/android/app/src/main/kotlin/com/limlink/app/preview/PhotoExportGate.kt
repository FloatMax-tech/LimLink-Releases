package com.limlink.app.preview

data class PhotoRecord(val uri: String, val published: Boolean)
interface PhotoExportBackend {
    fun find(key: String): PhotoRecord?
    fun create(key: String): String
    fun copyTo(uri: String)
    fun publish(uri: String)
    fun discard(uri: String)
}

/** The backend finds durable image rows, including an insert interrupted before journal commit. */
class PhotoExportGate {
    @Synchronized fun export(key: String, backend: PhotoExportBackend): String {
        backend.find(key)?.let { previous ->
            if (previous.published) return previous.uri
            backend.discard(previous.uri)
        }
        val uri = backend.create(key)
        try {
            backend.copyTo(uri)
            backend.publish(uri)
            return uri
        } catch (error: Exception) {
            runCatching { backend.discard(uri) }
            throw error
        }
    }
}
