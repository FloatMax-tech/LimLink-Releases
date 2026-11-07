package com.limlink.kit.storage

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import java.io.FileOutputStream

/**
 * User-picked folder. Bytes land in a ".limlink-part" file and are renamed on publish.
 * Providers that cannot rename fail safely; no public final file is ever copied in place.
 */
class SafTreeStore(
    private val context: Context,
    private val treeUri: Uri,
) : IncomingStore {
    private val resolver: ContentResolver = context.contentResolver

    override fun begin(desiredName: String, mimeType: String): PendingFile {
        val tree = requireTree()
        val existing = tree.listFiles().mapNotNull { it.name }
        val finalName = FileNames.resolveUnique(desiredName, existing)
        val partName = ".limlink-${java.util.UUID.randomUUID()}$PART_SUFFIX"
        val created = tree.createFile(mimeType.ifBlank { OCTET_STREAM }, partName)
            ?: error("Could not create a file in the chosen folder")
        PendingJournal.record(context, created.uri, "saf")
        return PendingFile(
            id = created.uri.toString(),
            finalName = finalName,
            locator = created.uri.toString(),
        )
    }

    override fun write(pending: PendingFile, bytes: ByteArray) {
        val uri = Uri.parse(pending.locator)
        val descriptor = resolver.openFileDescriptor(uri, "rw")
            ?: error("Could not open the chosen folder")
        descriptor.use { parcel ->
            FileOutputStream(parcel.fileDescriptor).use { output ->
                val channel = output.channel
                channel.position(channel.size())
                output.write(bytes)
                output.fd.sync()
            }
        }
    }

    override fun publish(pending: PendingFile): PublishedFile = synchronized(publicationLock) { publishLocked(pending) }

    private fun publishLocked(pending: PendingFile): PublishedFile {
        val source = Uri.parse(pending.locator)
        val tree = requireTree()
        val existing = tree.listFiles().mapNotNull { it.name }
        val finalName = FileNames.resolveUnique(pending.finalName, existing)
        val renamed = DocumentsContract.renameDocument(resolver, source, finalName)
            ?: error("Save provider cannot publish atomically")
        PendingJournal.forget(context, source)
        val name = DocumentFile.fromSingleUri(context, renamed)?.name ?: finalName
        return PublishedFile(displayName = name, locator = renamed.toString())
    }

    override fun discard(pending: PendingFile) {
        runCatching {
            DocumentsContract.deleteDocument(resolver, Uri.parse(pending.locator))
            PendingJournal.forget(context, Uri.parse(pending.locator))
        }
    }

    private fun requireTree(): DocumentFile {
        val tree = DocumentFile.fromTreeUri(context, treeUri)
            ?: error("Chosen folder is not available")
        check(tree.canWrite()) { "Chosen folder is not writable" }
        return tree
    }

    companion object {
        private val publicationLock = Any()
        const val PART_SUFFIX = ".limlink-part"
        private const val OCTET_STREAM = "application/octet-stream"
    }
}
