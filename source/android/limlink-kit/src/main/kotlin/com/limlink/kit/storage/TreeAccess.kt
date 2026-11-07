package com.limlink.kit.storage

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile

object TreeAccess {
    fun isWritable(context: Context, uri: Uri): Boolean {
        val persisted = context.contentResolver.persistedUriPermissions.any { permission ->
            permission.uri == uri && permission.isReadPermission && permission.isWritePermission
        }
        if (!persisted) return false
        val document = DocumentFile.fromTreeUri(context, uri) ?: return false
        return document.exists() && document.canWrite()
    }

    fun displayName(context: Context, uri: Uri): String? {
        return DocumentFile.fromTreeUri(context, uri)?.name
    }
}
