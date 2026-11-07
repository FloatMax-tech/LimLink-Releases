package com.limlink.kit.storage

data class PendingFile(
    val id: String,
    val finalName: String,
    val locator: String,
)

data class PublishedFile(
    val displayName: String,
    val locator: String,
)

/**
 * Write a file while it is still hidden, then publish it under its final name.
 * MediaStore does this with IS_PENDING. Other backends use a side file.
 */
interface IncomingStore {
    fun begin(desiredName: String, mimeType: String): PendingFile

    fun write(pending: PendingFile, bytes: ByteArray)

    fun publish(pending: PendingFile): PublishedFile

    fun discard(pending: PendingFile)
}

object SamplePayload {
    const val FILE_NAME = "limlink-sample.txt"
    const val MIME = "text/plain"

    val bytes: ByteArray = "LimLink sample\n".encodeToByteArray()

    fun write(store: IncomingStore): PublishedFile {
        val pending = store.begin(FILE_NAME, MIME)
        try {
            store.write(pending, bytes)
            return store.publish(pending)
        } catch (error: Throwable) {
            runCatching { store.discard(pending) }
            throw error
        }
    }
}
