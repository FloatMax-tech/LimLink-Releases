package com.limlink.app.preview

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONObject

enum class PhotoState { NONE, SAVING, SAVED, FAILED, DISABLED }
data class RecoveredPhoto(val target: PreviewTarget, val galleryUri: String?)

/** Only new verified receive events and explicit retries call export; startup never scans history. */
object PhotoLibrary {
    private val gate = PhotoExportGate()
    private val deletedReceipts = mutableSetOf<String>()
    private val mutableAutoSave = MutableStateFlow(true)
    private const val ATTEMPT = PhotoAttemptJournal.PREFIX
    private val albumPath get() = Environment.DIRECTORY_PICTURES + "/LimLink/"
    val autoSave = mutableAutoSave.asStateFlow()
    private fun prefs(context: Context) = context.getSharedPreferences("photo-library-v1", Context.MODE_PRIVATE)
    private fun attempts(context: Context) = PhotoAttemptJournal({ prefs(context).all }) { key, value ->
        val editor = prefs(context).edit()
        if (value == null) editor.remove(key) else editor.putString(key, value)
        editor.commit()
    }
    private fun receiptKey(target: PreviewTarget) = MessageDigest.getInstance("SHA-256")
        .digest("${target.locator}\n${target.name}\n${target.size}".toByteArray()).joinToString("") { "%02x".format(it) }
    fun initialize(context: Context) { mutableAutoSave.value = prefs(context).getBoolean("auto-save", true) }
    fun setAutoSave(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean("auto-save", enabled).apply()
        mutableAutoSave.value = enabled
    }

    private fun findOwned(context: Context, key: String): PhotoRecord? {
        val resolver = context.contentResolver
        val marker = "LimLink:$key"
        prefs(context).getString(key, null)?.let { cached ->
            val record = runCatching {
                resolver.query(Uri.parse(cached), arrayOf(MediaStore.Images.Media.IS_PENDING,
                    MediaStore.Images.Media.DESCRIPTION, MediaStore.Images.Media.RELATIVE_PATH), null, null, null)?.use {
                    if (it.moveToFirst() && it.getString(1) == marker && it.getString(2) == albumPath) PhotoRecord(cached, it.getInt(0) == 0) else null
                }
            }.getOrNull()
            if (record != null) return record
        }
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        return resolver.query(collection, arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.IS_PENDING),
            "${MediaStore.Images.Media.DESCRIPTION}=? AND ${MediaStore.Images.Media.RELATIVE_PATH}=?", arrayOf(marker, albumPath), null)?.use {
            if (it.moveToFirst()) PhotoRecord(ContentUris.withAppendedId(collection, it.getLong(0)).toString(), it.getInt(1) == 0) else null
        }
    }

    /** Recover only attempts persisted before insert. Never scan Downloads or enroll old history. */
    suspend fun recover(context: Context): List<RecoveredPhoto> = withContext(Dispatchers.IO) {
        synchronized(gate) {
            val journal = prefs(context)
            val attempts = attempts(context).enrolled().mapNotNull { (entryKey, value) ->
                runCatching {
                    val data = JSONObject(value)
                    val target = PreviewTarget(data.getString("locator"), data.getString("name"), data.getString("mime"),
                        data.getLong("size"), received = true, senderName = data.optString("sender").ifBlank { null })
                    require(PreviewPolicy.localLocator(target.locator))
                    entryKey to target
                }.getOrNull()
            }.toMap()
            val recovered = mutableListOf<RecoveredPhoto>()
            PhotoRecovery.reconcile(attempts.keys.toList(), object : PhotoRecoveryBackend {
                override fun find(key: String) = findOwned(context, key)
                override fun discard(uri: String) { context.contentResolver.delete(Uri.parse(uri), null, null) }
                override fun settle(key: String, publishedUri: String?) {
                    if (publishedUri != null) journal.edit().putString(key, publishedUri).remove(ATTEMPT + key).commit()
                    else journal.edit().remove(key).commit() // Keep enrolled metadata for a visible manual retry.
                    attempts[key]?.let { recovered += RecoveredPhoto(it, publishedUri) }
                }
            })
            recovered
        }
    }

    /** Call only after the user successfully deletes the received original. Gallery copies stay. */
    suspend fun forgetRecovery(context: Context, target: PreviewTarget) = withContext(Dispatchers.IO) {
        synchronized(gate) {
            val key = receiptKey(target)
            deletedReceipts += key // An already queued export cannot enroll this deleted receipt again.
            attempts(context).forget(key)
        }
    }

    suspend fun export(context: Context, target: PreviewTarget): String = withContext(Dispatchers.IO) {
        require(target.received && target.kind == PreviewKind.IMAGE)
        val resolver = context.contentResolver
        val key = receiptKey(target)
        val journal = prefs(context)
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val marker = "LimLink:$key"
        val path = albumPath
        synchronized(gate) {
        check(key !in deletedReceipts) { "Received original was deleted" }
        val attempt = JSONObject().put("locator", target.locator).put("name", target.name).put("mime", target.mime)
            .put("size", target.size).put("sender", target.senderName ?: "")
        attempts(context).enroll(key, attempt.toString())
        val exported = gate.export(key, object : PhotoExportBackend {
            override fun find(key: String) = findOwned(context, key)
            override fun create(key: String): String {
                val uri = requireNotNull(resolver.insert(collection, ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, target.name)
                    put(MediaStore.Images.Media.MIME_TYPE, PreviewPolicy.mime(target.name, target.mime))
                    put(MediaStore.Images.Media.RELATIVE_PATH, path)
                    put(MediaStore.Images.Media.DESCRIPTION, marker)
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }))
                if (!journal.edit().putString(key, uri.toString()).commit()) {
                    resolver.delete(uri, null, null)
                    error("Could not record pending photo")
                }
                return uri.toString()
            }
            override fun copyTo(uri: String) {
                // Reusing a published asset must work even if the original was later moved/deleted.
                // New copies validate a small actual image before publishing a renamed payload.
                val source = if (target.uri.scheme == "file") ImageDecoder.createSource(java.io.File(requireNotNull(target.uri.path)))
                else ImageDecoder.createSource(resolver, target.uri)
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    val ratio = maxOf(1.0, maxOf(info.size.width, info.size.height) / 64.0)
                    decoder.setTargetSize(maxOf(1, (info.size.width / ratio).toInt()), maxOf(1, (info.size.height / ratio).toInt()))
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }.recycle()
                target.open(context).use { input ->
                    requireNotNull(resolver.openOutputStream(Uri.parse(uri), "w")).use { output ->
                        val count = input.copyTo(output, 64 * 1024)
                        check(count == target.size) { "Received file is no longer complete" }
                    }
                }
            }
            override fun publish(uri: String) {
                check(resolver.update(Uri.parse(uri), ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null) > 0)
                journal.edit().putString(key, uri).remove(ATTEMPT + key).apply()
            }
            override fun discard(uri: String) {
                resolver.delete(Uri.parse(uri), null, null)
                journal.edit().remove(key).commit()
            }
        })
        journal.edit().putString(key, exported).remove(ATTEMPT + key).apply()
        exported
        }
    }
}
