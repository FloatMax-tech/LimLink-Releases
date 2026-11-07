package com.limlink.app.storage

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.limlink.kit.storage.IncomingStore
import com.limlink.kit.storage.MediaStoreDownloadsStore
import com.limlink.kit.storage.SafTreeStore
import com.limlink.kit.storage.SavePreference
import com.limlink.kit.storage.TreeAccess
import com.limlink.kit.storage.decideSaveLocation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

enum class LocationKind {
    DOWNLOADS,
    TREE_OK,
    TREE_UNAVAILABLE,
}

data class SaveLocationStatus(
    val kind: LocationKind,
    val treeUri: String?,
    val treeLabel: String?,
)

data class OpenedStore(
    val store: IncomingStore,
    val fellBackToDownloads: Boolean,
)

private val Context.settingsDataStore by preferencesDataStore(name = "limlink_settings")

class SaveLocationRepository(
    private val context: Context,
) {
    private val dataStore = context.applicationContext.settingsDataStore
    private val modeKey = stringPreferencesKey("save_mode")
    private val treeKey = stringPreferencesKey("save_tree_uri")

    val status: Flow<SaveLocationStatus> = dataStore.data.map { prefs ->
        val mode = prefs[modeKey]
        val tree = prefs[treeKey]
        if (mode != MODE_TREE || tree.isNullOrBlank()) {
            SaveLocationStatus(LocationKind.DOWNLOADS, null, null)
        } else {
            val uri = Uri.parse(tree)
            val label = TreeAccess.displayName(context, uri)
            val kind = if (TreeAccess.isWritable(context, uri)) {
                LocationKind.TREE_OK
            } else {
                LocationKind.TREE_UNAVAILABLE
            }
            SaveLocationStatus(kind, tree, label)
        }
    }

    suspend fun setTree(uri: Uri): Boolean {
        return try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            dataStore.edit { prefs ->
                prefs[modeKey] = MODE_TREE
                prefs[treeKey] = uri.toString()
            }
            true
        } catch (_: SecurityException) {
            false
        }
    }

    suspend fun setDownloads() {
        var previous: String? = null
        dataStore.edit { prefs ->
            previous = prefs[treeKey]
            prefs[modeKey] = MODE_DOWNLOADS
            prefs.remove(treeKey)
        }
        if (!previous.isNullOrBlank()) {
            runCatching {
                context.contentResolver.releasePersistableUriPermission(
                    Uri.parse(previous),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
        }
    }

    fun openStore(status: SaveLocationStatus): OpenedStore {
        val preference = if (status.kind == LocationKind.DOWNLOADS) {
            SavePreference.DOWNLOADS
        } else {
            SavePreference.TREE
        }
        val decision = decideSaveLocation(
            preference = preference,
            treeWritable = status.kind == LocationKind.TREE_OK,
        )
        val store = if (decision.useDownloads || status.treeUri.isNullOrBlank()) {
            MediaStoreDownloadsStore(context)
        } else {
            SafTreeStore(context, Uri.parse(status.treeUri))
        }
        return OpenedStore(store = store, fellBackToDownloads = decision.fellBack)
    }

    private companion object {
        const val MODE_DOWNLOADS = "downloads"
        const val MODE_TREE = "tree"
    }
}
