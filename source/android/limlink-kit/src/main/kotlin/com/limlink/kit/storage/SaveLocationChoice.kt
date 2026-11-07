package com.limlink.kit.storage

enum class SavePreference {
    DOWNLOADS,
    TREE,
}

data class SaveDecision(
    val useDownloads: Boolean,
    val fellBack: Boolean,
)

fun decideSaveLocation(preference: SavePreference, treeWritable: Boolean): SaveDecision {
    return when (preference) {
        SavePreference.DOWNLOADS -> SaveDecision(useDownloads = true, fellBack = false)
        SavePreference.TREE ->
            if (treeWritable) {
                SaveDecision(useDownloads = false, fellBack = false)
            } else {
                SaveDecision(useDownloads = true, fellBack = true)
            }
    }
}
