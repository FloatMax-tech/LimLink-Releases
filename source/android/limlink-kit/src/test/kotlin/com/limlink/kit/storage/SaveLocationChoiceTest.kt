package com.limlink.kit.storage

import org.junit.Assert.assertEquals
import org.junit.Test

class SaveLocationChoiceTest {
    @Test
    fun downloadsStayOnDownloads() {
        assertEquals(
            SaveDecision(useDownloads = true, fellBack = false),
            decideSaveLocation(SavePreference.DOWNLOADS, treeWritable = false),
        )
    }

    @Test
    fun writableTreeIsUsed() {
        assertEquals(
            SaveDecision(useDownloads = false, fellBack = false),
            decideSaveLocation(SavePreference.TREE, treeWritable = true),
        )
    }

    @Test
    fun missingTreeFallsBackWithoutForgettingThePreference() {
        assertEquals(
            SaveDecision(useDownloads = true, fellBack = true),
            decideSaveLocation(SavePreference.TREE, treeWritable = false),
        )
    }
}
