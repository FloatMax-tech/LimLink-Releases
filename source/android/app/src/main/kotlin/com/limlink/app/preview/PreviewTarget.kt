package com.limlink.app.preview

import android.content.Context
import android.net.Uri
import java.io.Closeable
import java.io.File
import java.io.InputStream

class PreviewTarget(
    val locator: String,
    val name: String,
    val mime: String,
    val size: Long,
    val received: Boolean = false,
    val originalLocator: String? = null,
    val galleryUri: String? = null,
    private val lease: Closeable? = null,
    val senderName: String? = null,
) : Closeable {
    val kind get() = PreviewPolicy.kind(name, mime)
    val uri: Uri get() = if (locator.startsWith('/')) Uri.fromFile(File(locator)) else Uri.parse(locator)
    fun open(context: Context): InputStream {
        require(PreviewPolicy.localLocator(locator))
        return if (uri.scheme == "file") {
            if (!PreviewPolicy.fileAvailable(locator)) throw java.io.FileNotFoundException(name)
            File(requireNotNull(uri.path)).inputStream()
        }
        else requireNotNull(context.contentResolver.openInputStream(uri))
    }
    override fun close() { lease?.close() }
}
