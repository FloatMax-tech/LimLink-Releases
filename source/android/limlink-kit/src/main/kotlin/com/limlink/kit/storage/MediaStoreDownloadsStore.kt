package com.limlink.kit.storage

import android.content.ContentResolver
import android.content.ContentValues
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.FileOutputStream

/**
 * Default save location: the public Download folder.
 * The row stays IS_PENDING until [publish], so other apps cannot see a partial file.
 */
class MediaStoreDownloadsStore(
    private val context: android.content.Context,
) : IncomingStore {
    private val resolver = context.contentResolver
    override fun begin(desiredName: String, mimeType: String): PendingFile {
        val finalName = FileNames.resolveUnique(desiredName, queryNames())
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, finalName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType.ifBlank { OCTET_STREAM })
            put(MediaStore.MediaColumns.RELATIVE_PATH, DOWNLOADS_PATH)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("MediaStore insert failed")
        PendingJournal.record(context, uri, "media")
        val actual = queryDisplayName(uri) ?: finalName
        return PendingFile(id = uri.toString(), finalName = actual, locator = uri.toString())
    }

    override fun write(pending: PendingFile, bytes: ByteArray) {
        val uri = Uri.parse(pending.locator)
        val descriptor = resolver.openFileDescriptor(uri, "rw")
            ?: error("Could not open pending download")
        descriptor.use { parcel ->
            FileOutputStream(parcel.fileDescriptor).use { output ->
                val channel = output.channel
                channel.position(channel.size())
                output.write(bytes)
                output.fd.sync()
            }
        }
    }

    override fun publish(pending: PendingFile): PublishedFile {
        val uri = Uri.parse(pending.locator)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }
        val updated = resolver.update(uri, values, null, null)
        check(updated > 0) { "Could not publish pending download" }
        PendingJournal.forget(context, uri)
        val name = queryDisplayName(uri) ?: pending.finalName
        return PublishedFile(displayName = name, locator = uri.toString())
    }

    override fun discard(pending: PendingFile) {
        resolver.delete(Uri.parse(pending.locator), null, null)
        PendingJournal.forget(context, Uri.parse(pending.locator))
    }

    private fun queryNames(): List<String> {
        val names = mutableListOf<String>()
        resolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            while (cursor.moveToNext()) {
                cursor.getString(index)?.let(names::add)
            }
        }
        return names
    }

    private fun queryDisplayName(uri: Uri): String? {
        resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            val index = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            return cursor.getString(index)
        }
        return null
    }

    companion object {
        val DOWNLOADS_PATH: String = Environment.DIRECTORY_DOWNLOADS + "/"
        private const val OCTET_STREAM = "application/octet-stream"
    }
}
