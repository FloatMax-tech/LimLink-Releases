package com.limlink.kit.storage

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore

/** Recover only known unfinished publications. A renamed/published final file is never removed. */
object PendingJournal {
    private fun prefs(context: Context) = context.getSharedPreferences("limlink-pending-publications", Context.MODE_PRIVATE)
    @Synchronized fun record(context: Context, uri: Uri, kind: String) {
        if (!prefs(context).edit().putString(uri.toString(), kind).commit()) {
            if (kind == "saf") DocumentsContract.deleteDocument(context.contentResolver, uri)
            else context.contentResolver.delete(uri, null, null)
            error("Could not journal pending publication")
        }
    }
    @Synchronized fun forget(context: Context, uri: Uri) { prefs(context).edit().remove(uri.toString()).commit() }
    @Synchronized fun recover(context: Context) {
        val resolver = context.contentResolver
        prefs(context).all.forEach { (text, kind) ->
            val uri = Uri.parse(text)
            runCatching {
                val column = if (kind == "saf") DocumentsContract.Document.COLUMN_DISPLAY_NAME else MediaStore.MediaColumns.IS_PENDING
                val pending = resolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
                    if (!cursor.moveToFirst()) false
                    else if (kind == "saf") cursor.getString(0).let { it.startsWith(".limlink-") && it.endsWith(SafTreeStore.PART_SUFFIX) }
                    else cursor.getInt(0) == 1
                } ?: false
                if (pending) {
                    if (kind == "saf") DocumentsContract.deleteDocument(resolver, uri)
                    else resolver.delete(uri, null, null)
                }
                forget(context, uri)
            }
        }
    }
}
