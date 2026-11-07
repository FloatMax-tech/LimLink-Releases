package com.limlink.app.preview

import android.content.Context
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

object FileActions {
    private data class ExternalFile(val uri: Uri, val directory: File? = null)
    /** A snapshot copy outlives the preview lease while another app reads its granted URI. */
    private suspend fun externalUri(context: Context, target: PreviewTarget): ExternalFile {
        var created: File? = null
        try {
            return withContext(Dispatchers.IO) {
                if (target.uri.scheme == "content") return@withContext ExternalFile(target.uri)
                val directory = File(context.cacheDir, "preview-share").apply { mkdirs() }
                directory.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L }?.forEach { it.deleteRecursively() }
                check(target.size in 0..(512L * 1024 * 1024))
                val folder = File(directory, java.util.UUID.randomUUID().toString()).apply { mkdirs() }
                created = folder
                val destination = File(folder, File(target.name).name.take(180).ifBlank { "file" })
                val coroutine = currentCoroutineContext()
                PreviewCacheCopy.copy({ target.open(context) }, destination, 512L * 1024 * 1024) { coroutine.ensureActive() }
                coroutine.ensureActive()
                ExternalFile(FileProvider.getUriForFile(context, "${context.packageName}.preview-files", destination), folder)
            }
        } catch (error: Exception) {
            withContext(NonCancellable + Dispatchers.IO) { created?.deleteRecursively() }
            throw error
        }
    }
    private suspend fun handoff(context: Context, target: PreviewTarget, intent: (Uri) -> Intent) {
        val external = externalUri(context, target)
        try {
            currentCoroutineContext().ensureActive()
            context.startActivity(Intent.createChooser(intent(external.uri), null))
        } catch (error: Exception) {
            withContext(NonCancellable + Dispatchers.IO) { external.directory?.deleteRecursively() }
            throw error
        }
    }

    suspend fun openWith(context: Context, target: PreviewTarget) {
        handoff(context, target) { uri -> Intent(Intent.ACTION_VIEW).setDataAndType(uri, target.mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }
    }

    suspend fun share(context: Context, target: PreviewTarget) {
        handoff(context, target) { uri -> Intent(Intent.ACTION_SEND).setType(target.mime)
            .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .apply { clipData = ClipData.newRawUri(target.name, uri) } }
    }

    fun gallery(context: Context, uri: String) {
        context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(uri), "image/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }

    /** Android providers may show a location sheet instead of revealing an exact parent folder. */
    fun location(context: Context, target: PreviewTarget) {
        val initial = target.originalLocator ?: target.locator
        val uri = if (initial.startsWith("content://")) Uri.parse(initial) else null
        context.startActivity(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            if (uri != null) putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
        })
    }
}
